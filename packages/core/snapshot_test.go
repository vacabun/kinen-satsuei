package kinen

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/object"
)

func TestSnapshotScope(t *testing.T) {
	ctx := context.Background()
	source := t.TempDir()
	if err := os.CopyFS(source, os.DirFS("../../fixtures/library-v1")); err != nil {
		t.Fatal(err)
	}
	const localCredential = ".git-connection.dpapi"
	if err := os.WriteFile(filepath.Join(source, localCredential), []byte("local only"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, directory := range []string{".drafts", ".git"} {
		if err := os.Mkdir(filepath.Join(source, directory), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(source, directory, "private.md"), []byte("local only"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	oversized := "assets/cheki/too-large.png"
	file, err := os.Create(filepath.Join(source, filepath.FromSlash(oversized)))
	if err != nil {
		t.Fatal(err)
	}
	if err := errors.Join(file.Truncate(AttachmentLimit+1), file.Close()); err != nil {
		t.Fatal(err)
	}
	r := &Remote{repo: openRepository(t, true)}
	author := object.Signature{Name: "Kinen", Email: "test@example.invalid", When: time.Now()}
	for _, attachments := range []bool{false, true} {
		result, err := r.CommitSnapshot(ctx, source, plumbing.ZeroHash, author, attachments)
		if err != nil {
			t.Fatal(err)
		}
		if attachments && (len(result.Omitted) != 1 || result.Omitted[0] != oversized) {
			t.Fatalf("oversized attachment report = %v", result.Omitted)
		}
		destination := filepath.Join(t.TempDir(), "restored")
		if err := r.ExportSnapshot(ctx, result.Commit, destination); err != nil {
			t.Fatal(err)
		}
		excluded := []string{".drafts", ".git", oversized, localCredential}
		if !attachments {
			excluded = append(excluded, "assets")
		}
		for _, name := range excluded {
			if _, err := os.Stat(filepath.Join(destination, filepath.FromSlash(name))); !errors.Is(err, fs.ErrNotExist) {
				t.Fatalf("excluded file %s: %v", name, err)
			}
		}
		if err := r.ExportSnapshot(ctx, result.Commit, destination); !errors.Is(err, fs.ErrExist) {
			t.Fatalf("export over existing folder = %v", err)
		}
	}
}
