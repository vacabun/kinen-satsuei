// Package kinen provides portable Git operations for the Kinen library.
package kinen

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"

	git "github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/config"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/transport"
	gitssh "github.com/go-git/go-git/v5/plumbing/transport/ssh"
	"golang.org/x/crypto/ssh"
)

type HostKeyError struct {
	Observed string
	Expected string
}

func (e *HostKeyError) Error() string {
	if e.Expected == "" {
		return "SSH host key needs verification: " + e.Observed
	}
	return "SSH host key changed: " + e.Observed
}

var sshUser = regexp.MustCompile("^[A-Za-z0-9_.-]+$")
var sshPath = regexp.MustCompile("^/[A-Za-z0-9._~ /-]+$")
var sshHost = regexp.MustCompile("^[A-Za-z0-9.:-]+$")

// Remote uses a dedicated local Git repository. Share one instance per repository.
type Remote struct {
	mu     sync.Mutex
	repo   *git.Repository
	branch plumbing.ReferenceName
	url    string
	auth   transport.AuthMethod
	pin    string
}

// NewSSHRemote validates the configuration without making a network request.
// An empty fingerprint results in a HostKeyError on first contact.
func NewSSHRemote(repo *git.Repository, endpoint, branch string, privateKey, passphrase []byte, fingerprint string) (*Remote, error) {
	parsed, err := url.Parse(endpoint)
	if err != nil || parsed.Scheme != "ssh" || !sshHost.MatchString(parsed.Hostname()) ||
		!sshPath.MatchString(parsed.Path) || strings.HasPrefix(parsed.Path, "//") ||
		parsed.ForceQuery || parsed.RawQuery != "" || strings.Contains(endpoint, "#") {
		return nil, errors.New("invalid Git SSH URL")
	}
	if port := parsed.Port(); port != "" {
		number, err := strconv.Atoi(port)
		if err != nil || number < 1 || number > 65535 {
			return nil, errors.New("invalid Git SSH port")
		}
	}
	user := "git"
	if parsed.User != nil {
		user = parsed.User.Username()
		if _, hasPassword := parsed.User.Password(); hasPassword || !sshUser.MatchString(user) {
			return nil, errors.New("invalid Git SSH user")
		}
	}
	ref := plumbing.NewBranchReferenceName(branch)
	if branch == "" || strings.HasPrefix(branch, "-") || ref.Validate() != nil {
		return nil, errors.New("invalid Git branch")
	}
	if fingerprint != "" {
		digest, err := base64.RawStdEncoding.Strict().DecodeString(strings.TrimPrefix(fingerprint, "SHA256:"))
		if !strings.HasPrefix(fingerprint, "SHA256:") || err != nil || len(digest) != 32 {
			return nil, errors.New("invalid SSH host fingerprint")
		}
	}
	var signer ssh.Signer
	if len(passphrase) == 0 {
		signer, err = ssh.ParsePrivateKey(privateKey)
	} else {
		signer, err = ssh.ParsePrivateKeyWithPassphrase(privateKey, passphrase)
	}
	if err != nil {
		return nil, fmt.Errorf("read SSH private key: %w", err)
	}
	parsed.User = url.User(user)
	return &Remote{repo: repo, branch: ref, url: parsed.String(),
		auth: &gitssh.PublicKeys{User: user, Signer: signer}, pin: fingerprint}, nil
}

const remoteName = "kinen"
const fetchedRef = "refs/kinen/fetched"
const outgoingRef = "refs/heads/kinen-outgoing"

func (r *Remote) connection() (*git.Remote, transport.AuthMethod, **HostKeyError) {
	var rejected *HostKeyError
	auth := r.auth
	if keys, ok := auth.(*gitssh.PublicKeys); ok {
		credentials := *keys
		credentials.HostKeyCallback = func(_ string, _ net.Addr, key ssh.PublicKey) error {
			fingerprint := ssh.FingerprintSHA256(key)
			if fingerprint == r.pin {
				return nil
			}
			rejected = &HostKeyError{Observed: fingerprint, Expected: r.pin}
			return rejected
		}
		auth = &credentials
	}
	return git.NewRemote(r.repo.Storer, &config.RemoteConfig{Name: remoteName, URLs: []string{r.url}}), auth, &rejected
}

// Fetch downloads the configured branch and returns its tip. A missing branch
// has the zero hash, even when an earlier fetch downloaded a now-deleted branch.
func (r *Remote) Fetch(ctx context.Context) (plumbing.Hash, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	remote, auth, rejected := r.connection()
	err := remote.FetchContext(ctx, &git.FetchOptions{
		Auth: auth, Tags: git.NoTags,
		RefSpecs: []config.RefSpec{config.RefSpec("+" + r.branch.String() + ":" + fetchedRef)},
	})
	if *rejected != nil {
		return plumbing.ZeroHash, *rejected
	}
	if errors.Is(err, transport.ErrEmptyRemoteRepository) || errors.Is(err, git.NoMatchingRefSpecError{}) {
		return plumbing.ZeroHash, nil
	}
	if err != nil && !errors.Is(err, git.NoErrAlreadyUpToDate) {
		return plumbing.ZeroHash, err
	}
	tip, err := r.repo.Reference(fetchedRef, false)
	if err != nil {
		return plumbing.ZeroHash, err
	}
	return tip.Hash(), nil
}

// Push uploads a new snapshot commit on top of expected. The server must still
// advertise expected (or no branch for an initial commit) before it is updated.
func (r *Remote) Push(ctx context.Context, expected, next plumbing.Hash) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	commit, err := r.repo.CommitObject(next)
	if err != nil {
		return err
	}
	if (expected.IsZero() && len(commit.ParentHashes) != 0) ||
		(!expected.IsZero() && (len(commit.ParentHashes) != 1 || commit.ParentHashes[0] != expected)) {
		return errors.New("snapshot commit is not based on the expected remote revision")
	}
	// go-git uses the tracking ref as the lease when the expected hash is zero.
	for name, hash := range map[plumbing.ReferenceName]plumbing.Hash{
		outgoingRef: next, "refs/remotes/kinen/kinen-outgoing": expected,
	} {
		if err := r.repo.Storer.SetReference(plumbing.NewHashReference(name, hash)); err != nil {
			return err
		}
	}
	remote, auth, rejected := r.connection()
	err = remote.PushContext(ctx, &git.PushOptions{
		RemoteName: remoteName, Auth: auth,
		RefSpecs:       []config.RefSpec{config.RefSpec(outgoingRef + ":" + r.branch.String())},
		ForceWithLease: &git.ForceWithLease{RefName: r.branch, Hash: expected},
	})
	if *rejected != nil {
		return *rejected
	}
	if errors.Is(err, git.NoErrAlreadyUpToDate) {
		return nil
	}
	return err
}
