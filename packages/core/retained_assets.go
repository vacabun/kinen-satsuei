package kinen

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path"

	"github.com/go-git/go-git/v5/plumbing/filemode"
	"github.com/go-git/go-git/v5/plumbing/object"
)

type mediaAsset struct {
	SHA256         string
	ByteLength     int64
	StoredFilename *string
}

func (a *mediaAsset) relativePath() (string, error) {
	if len(a.SHA256) != 64 || a.ByteLength <= 0 {
		return "", errors.New("invalid media asset metadata")
	}
	name := "assets/sha256/" + a.SHA256[:2] + "/" + a.SHA256
	if a.StoredFilename != nil {
		name = "assets/cheki/" + *a.StoredFilename
	}
	if !isAsset(name) {
		return "", errors.New("invalid media asset path")
	}
	return name, nil
}

// retainAssets keeps still-referenced attachments that already exist remotely.
// A change in upload scope never causes silent loss of a matching attachment.
func (r *Remote) retainAssets(ctx context.Context, source *os.Root, parent *object.Commit,
	entries map[string][]object.TreeEntry, included map[string]bool) error {
	tree, err := parent.Tree()
	if err != nil {
		return err
	}
	for _, record := range entries["media"] {
		if err := ctx.Err(); err != nil {
			return err
		}
		data, err := source.ReadFile("media/" + record.Name)
		if err != nil {
			return err
		}
		var media struct{ Original, Corrected *mediaAsset }
		if err := json.Unmarshal(data, &media); err != nil {
			return err
		}
		for _, asset := range []*mediaAsset{media.Original, media.Corrected} {
			if asset == nil || asset.ByteLength > AttachmentLimit {
				continue
			}
			name, err := asset.relativePath()
			if err != nil {
				return err
			}
			if included[name] {
				continue
			}
			entry, err := tree.FindEntry(name)
			if errors.Is(err, object.ErrEntryNotFound) || errors.Is(err, object.ErrDirectoryNotFound) {
				continue
			}
			if err != nil {
				return err
			}
			if entry.Mode != filemode.Regular {
				return fmt.Errorf("invalid previous attachment: %s", name)
			}
			blob, err := r.repo.BlobObject(entry.Hash)
			if err != nil {
				return err
			}
			if blob.Size != asset.ByteLength {
				continue
			}
			reader, err := blob.Reader()
			if err != nil {
				return err
			}
			digest := sha256.New()
			err = copySnapshotBytes(digest, reader, blob.Size)
			if err := errors.Join(err, reader.Close()); err != nil {
				return err
			}
			if hex.EncodeToString(digest.Sum(nil)) != asset.SHA256 {
				continue
			}
			dir := path.Dir(name)
			entries[dir] = append(entries[dir], *entry)
			included[name] = true
		}
	}
	return nil
}
