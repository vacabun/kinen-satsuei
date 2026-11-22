package kinen

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/filemode"
	"github.com/go-git/go-git/v5/plumbing/object"
)

const AttachmentLimit = 95 * 1024 * 1024
const metadataLimit = 16 * 1024 * 1024
const snapshotFileLimit = 200_000

const libraryID = `[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`

var metadataPath = regexp.MustCompile(`^(library\.json|(members|groups|media)/` + libraryID + `\.json|entries/` + libraryID + `/(entry\.json|body\.md))$`)
var metadataDirectory = regexp.MustCompile(`^(members|groups|media|entries|entries/` + libraryID + `)$`)
var hashedAssetPath = regexp.MustCompile(`^assets/sha256/[0-9a-f]{2}/[0-9a-f]{64}$`)
var chekiAssetPath = regexp.MustCompile(`^assets/cheki/[a-z0-9_-][a-z0-9_.-]{0,254}$`)
var assetDirectory = regexp.MustCompile(`^assets(/(cheki|sha256(/[0-9a-f]{2})?))?$`)

func isAsset(name string) bool {
	if hashedAssetPath.MatchString(name) {
		return path.Base(path.Dir(name)) == path.Base(name)[:2]
	}
	if !chekiAssetPath.MatchString(name) || strings.HasSuffix(name, ".") {
		return false
	}
	// Git filenames must also be usable on Windows.
	base, _, _ := strings.Cut(path.Base(name), ".")
	switch base {
	case "con", "prn", "aux", "nul", "com0", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
		"lpt0", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9":
		return false
	}
	return true
}

// Snapshot builds a Git commit from an immutable, validated library export.
// Omitted reports assets excluded by the size limit when attachments are enabled.
// Existing remote attachments are retained when they still match a record.
type Snapshot struct {
	Commit  plumbing.Hash
	Omitted []string
}

func (r *Remote) CommitSnapshot(ctx context.Context, source string, parent plumbing.Hash, author object.Signature, includeAttachments bool) (Snapshot, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	var result Snapshot
	root, err := os.OpenRoot(source)
	if err != nil {
		return result, err
	}
	defer root.Close()
	var parentCommit *object.Commit
	if !parent.IsZero() {
		parentCommit, err = r.repo.CommitObject(parent)
		if err != nil {
			return result, err
		}
	}

	entries := make(map[string][]object.TreeEntry)
	included := make(map[string]bool)
	files := 0
	hasManifest := false
	err = fs.WalkDir(root.FS(), ".", func(name string, item fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if name == "." {
			return nil
		}
		if item.IsDir() {
			if metadataDirectory.MatchString(name) || includeAttachments && assetDirectory.MatchString(name) {
				return nil
			}
			return fs.SkipDir
		}
		attachment := includeAttachments && isAsset(name)
		if !metadataPath.MatchString(name) && !attachment {
			return nil
		}
		info, err := item.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("invalid snapshot file: %s", name)
		}
		files++
		if files > snapshotFileLimit {
			return errors.New("snapshot contains too many files")
		}
		if attachment && info.Size() > AttachmentLimit {
			result.Omitted = append(result.Omitted, name)
			return nil
		}
		if !attachment && info.Size() > metadataLimit {
			return fmt.Errorf("snapshot metadata exceeds size limit: %s", name)
		}
		hash, err := r.storeBlob(root, name, info.Size())
		if err != nil {
			return err
		}
		if attachment {
			included[name] = true
		}
		directory := path.Dir(name)
		entries[directory] = append(entries[directory], object.TreeEntry{
			Name: path.Base(name), Hash: hash, Mode: filemode.Regular,
		})
		hasManifest = hasManifest || name == "library.json"
		return nil
	})
	if err != nil {
		return Snapshot{}, err
	}
	if !hasManifest {
		return Snapshot{}, errors.New("snapshot is missing library.json")
	}
	if parentCommit != nil {
		if err := r.retainAssets(ctx, root, parentCommit, entries, included); err != nil {
			return Snapshot{}, err
		}
	}
	directories := make([]string, 0, len(entries))
	seen := map[string]bool{".": true}
	for dir := range entries {
		for !seen[dir] {
			seen[dir] = true
			directories = append(directories, dir)
			dir = path.Dir(dir)
		}
	}
	// Children precede their parent in reverse lexical order.
	sort.Sort(sort.Reverse(sort.StringSlice(directories)))
	directories = append(directories, ".")
	var treeHash plumbing.Hash
	for _, dir := range directories {
		if err := ctx.Err(); err != nil {
			return Snapshot{}, err
		}
		sort.Sort(object.TreeEntrySorter(entries[dir]))
		tree := object.Tree{Entries: entries[dir]}
		value := r.repo.Storer.NewEncodedObject()
		if err := tree.Encode(value); err != nil {
			return Snapshot{}, err
		}
		treeHash, err = r.repo.Storer.SetEncodedObject(value)
		if err != nil {
			return Snapshot{}, err
		}
		if dir != "." {
			parentDir := path.Dir(dir)
			entries[parentDir] = append(entries[parentDir], object.TreeEntry{
				Name: path.Base(dir), Hash: treeHash, Mode: filemode.Dir,
			})
		}
	}
	commit := object.Commit{TreeHash: treeHash, Author: author, Committer: author, Message: "Update Kinen library"}
	if !parent.IsZero() {
		commit.ParentHashes = []plumbing.Hash{parent}
	}
	value := r.repo.Storer.NewEncodedObject()
	if err := commit.Encode(value); err != nil {
		return Snapshot{}, err
	}
	result.Commit, err = r.repo.Storer.SetEncodedObject(value)
	return result, err
}

func (r *Remote) storeBlob(root *os.Root, name string, size int64) (plumbing.Hash, error) {
	file, err := root.Open(name)
	if err != nil {
		return plumbing.ZeroHash, err
	}
	defer file.Close()
	blob := r.repo.Storer.NewEncodedObject()
	blob.SetType(plumbing.BlobObject)
	blob.SetSize(size)
	writer, err := blob.Writer()
	if err != nil {
		return plumbing.ZeroHash, err
	}
	err = copySnapshotBytes(writer, file, size)
	closeErr := writer.Close()
	if err := errors.Join(err, closeErr); err != nil {
		return plumbing.ZeroHash, err
	}
	return r.repo.Storer.SetEncodedObject(blob)
}

func copySnapshotBytes(destination io.Writer, source io.Reader, size int64) error {
	written, err := io.Copy(destination, io.LimitReader(source, size+1))
	if err == nil && written != size {
		return errors.New("snapshot file size changed")
	}
	return err
}

// ExportSnapshot writes a commit into a new directory under a caller-controlled
// parent. Callers must validate the exported library before activating it.
func (r *Remote) ExportSnapshot(ctx context.Context, revision plumbing.Hash, destination string) error {
	r.mu.Lock()
	defer r.mu.Unlock()

	commit, err := r.repo.CommitObject(revision)
	if err != nil {
		return err
	}
	tree, err := commit.Tree()
	if err != nil {
		return err
	}
	stage, err := os.MkdirTemp(filepath.Dir(destination), ".kinen-snapshot-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)

	hasManifest := false
	files := 0
	var writeTree func(string, *object.Tree) error
	writeTree = func(prefix string, tree *object.Tree) error {
		for _, entry := range tree.Entries {
			if err := ctx.Err(); err != nil {
				return err
			}
			name := path.Join(prefix, entry.Name)
			if strings.ContainsAny(entry.Name, "/\\") || entry.Name == "." || entry.Name == ".." {
				return fmt.Errorf("invalid Git tree name: %q", entry.Name)
			}
			files++
			if files > snapshotFileLimit*2 {
				return errors.New("snapshot tree contains too many entries")
			}
			if entry.Mode == filemode.Dir {
				if !metadataDirectory.MatchString(name) && !assetDirectory.MatchString(name) {
					return fmt.Errorf("unexpected snapshot directory: %s", name)
				}
				child, err := r.repo.TreeObject(entry.Hash)
				if err != nil {
					return err
				}
				if err := writeTree(name, child); err != nil {
					return err
				}
				continue
			}
			maxSize := int64(metadataLimit)
			if isAsset(name) {
				maxSize = AttachmentLimit
			} else if !metadataPath.MatchString(name) {
				return fmt.Errorf("unexpected snapshot file: %s", name)
			}
			if entry.Mode != filemode.Regular {
				return fmt.Errorf("invalid snapshot file mode: %s", name)
			}
			blob, err := r.repo.BlobObject(entry.Hash)
			if err != nil {
				return err
			}
			if blob.Size < 0 || blob.Size > maxSize {
				return fmt.Errorf("invalid snapshot file size: %s", name)
			}
			if err := exportBlob(blob, filepath.Join(stage, filepath.FromSlash(name))); err != nil {
				return err
			}
			hasManifest = hasManifest || name == "library.json"
		}
		return nil
	}
	if err := writeTree("", tree); err != nil {
		return err
	}
	if !hasManifest {
		return errors.New("snapshot is missing library.json")
	}
	if _, err := os.Lstat(destination); !errors.Is(err, os.ErrNotExist) {
		if err != nil {
			return err
		}
		return fs.ErrExist
	}
	return os.Rename(stage, destination)
}

func exportBlob(blob *object.Blob, destination string) error {
	reader, err := blob.Reader()
	if err != nil {
		return err
	}
	defer reader.Close()
	if err := os.MkdirAll(filepath.Dir(destination), 0700); err != nil {
		return err
	}
	file, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	copyErr := copySnapshotBytes(file, reader, blob.Size)
	return errors.Join(copyErr, file.Close())
}
