package kinen

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
	"time"

	git "github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/object"
	"golang.org/x/crypto/ssh"
)

func openRepository(t *testing.T, bare bool) *git.Repository {
	t.Helper()
	repo, err := git.PlainInit(t.TempDir(), bare)
	if err != nil {
		t.Fatal(err)
	}
	return repo
}

func snapshot(t *testing.T, repo *git.Repository, parent plumbing.Hash, message string) plumbing.Hash {
	t.Helper()
	tree := repo.Storer.NewEncodedObject()
	if err := (&object.Tree{}).Encode(tree); err != nil {
		t.Fatal(err)
	}
	treeHash, err := repo.Storer.SetEncodedObject(tree)
	if err != nil {
		t.Fatal(err)
	}
	author := object.Signature{Name: "Kinen", Email: "test@example.invalid", When: time.Now()}
	commit := object.Commit{TreeHash: treeHash, Author: author, Committer: author, Message: message}
	if !parent.IsZero() {
		commit.ParentHashes = []plumbing.Hash{parent}
	}
	value := repo.Storer.NewEncodedObject()
	if err := commit.Encode(value); err != nil {
		t.Fatal(err)
	}
	hash, err := repo.Storer.SetEncodedObject(value)
	if err != nil {
		t.Fatal(err)
	}
	return hash
}

func checkRoundTrip(t *testing.T, first, second *Remote) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	checkTip := func(remote *Remote, want plumbing.Hash) {
		t.Helper()
		got, err := remote.Fetch(ctx)
		if err != nil || got != want {
			t.Fatalf("Fetch() = %s, %v; want %s", got, err, want)
		}
	}
	checkTip(first, plumbing.ZeroHash)
	fixture := "../../fixtures/library-v1"
	staged, err := first.CommitSnapshot(ctx, fixture, plumbing.ZeroHash,
		object.Signature{Name: "Kinen", Email: "test@example.invalid", When: time.Now()}, true)
	if err != nil {
		t.Fatal(err)
	}
	initial := staged.Commit
	if err := first.Push(ctx, plumbing.ZeroHash, initial); err != nil {
		t.Fatal(err)
	}
	unrelated := snapshot(t, second.repo, plumbing.ZeroHash, "concurrent creation")
	if err := second.Push(ctx, plumbing.ZeroHash, unrelated); err == nil {
		t.Fatal("stale branch creation succeeded")
	}
	checkTip(second, initial)
	restored := filepath.Join(t.TempDir(), "restored")
	if err := second.ExportSnapshot(ctx, initial, restored); err != nil {
		t.Fatal(err)
	}
	if err := fs.WalkDir(os.DirFS(fixture), ".", func(name string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return err
		}
		want, err := os.ReadFile(filepath.Join(fixture, filepath.FromSlash(name)))
		if err != nil {
			return err
		}
		got, err := os.ReadFile(filepath.Join(restored, filepath.FromSlash(name)))
		if err != nil {
			return err
		}
		if !bytes.Equal(got, want) {
			t.Errorf("restored file differs: %s", name)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	edit := t.TempDir()
	if err := os.CopyFS(edit, os.DirFS(restored)); err != nil {
		t.Fatal(err)
	}
	assetPaths, err := filepath.Glob(filepath.Join(edit, "assets", "cheki", "*.png"))
	if err != nil || len(assetPaths) != 1 {
		t.Fatalf("fixture attachment was not restored: %v", err)
	}
	if err := os.Remove(assetPaths[0]); err != nil {
		t.Fatal(err)
	}
	nextSnapshot, err := first.CommitSnapshot(ctx, edit, initial,
		object.Signature{Name: "Kinen", Email: "test@example.invalid", When: time.Now()}, false)
	if err != nil {
		t.Fatal(err)
	}
	next := nextSnapshot.Commit
	stale := snapshot(t, second.repo, initial, "stale update")
	if err := first.Push(ctx, initial, next); err != nil {
		t.Fatal(err)
	}
	if err := second.Push(ctx, initial, stale); err == nil {
		t.Fatal("stale branch update succeeded")
	}
	checkTip(second, next)
	updated := filepath.Join(t.TempDir(), "updated")
	if err := second.ExportSnapshot(ctx, next, updated); err != nil {
		t.Fatal(err)
	}
	relative, err := filepath.Rel(edit, assetPaths[0])
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(updated, relative))
	if err != nil {
		t.Fatal(err)
	}
	want, err := os.ReadFile(filepath.Join(restored, relative))
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("previous remote attachment changed: %v", err)
	}
}

func TestRemoteRoundTrip(t *testing.T) {
	dir := t.TempDir()
	if _, err := git.PlainInit(dir, true); err != nil {
		t.Fatal(err)
	}
	branch := plumbing.NewBranchReferenceName("library")
	checkRoundTrip(t,
		&Remote{repo: openRepository(t, true), url: dir, branch: branch},
		&Remote{repo: openRepository(t, true), url: dir, branch: branch},
	)
}

func TestSSHHostKeyAndRoundTrip(t *testing.T) {
	endpoint := os.Getenv("KINEN_TEST_SSH_URL")
	if endpoint == "" {
		t.Skip("requires disposable empty SSH repository and test keys")
	}
	dir := os.Getenv("KINEN_TEST_SSH_KEY_FOLDER")
	key, err := os.ReadFile(filepath.Join(dir, "client"))
	if err != nil {
		t.Fatal(err)
	}
	hostKey, err := os.ReadFile(filepath.Join(dir, "host.pub"))
	if err != nil {
		t.Fatal(err)
	}
	host, _, _, _, err := ssh.ParseAuthorizedKey(hostKey)
	if err != nil {
		t.Fatal(err)
	}
	fingerprint := ssh.FingerprintSHA256(host)
	connect := func(pin string) *Remote {
		t.Helper()
		remote, err := NewSSHRemote(openRepository(t, true), endpoint, "library", key, nil, pin)
		if err != nil {
			t.Fatal(err)
		}
		return remote
	}
	arbitrary, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	different, err := ssh.NewPublicKey(arbitrary)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	for _, pin := range []string{"", ssh.FingerprintSHA256(different)} {
		_, err := connect(pin).Fetch(ctx)
		var rejected *HostKeyError
		if !errors.As(err, &rejected) || rejected.Observed != fingerprint || rejected.Expected != pin {
			t.Fatalf("Fetch with fingerprint %q = %v", pin, err)
		}
	}
	checkRoundTrip(t, connect(fingerprint), connect(fingerprint))
}
