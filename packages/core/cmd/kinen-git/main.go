// kinen-git exposes remote snapshot backup and recovery to desktop applications.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/object"
	kinen "github.com/vacabun/kinen-satsuei/core"
)

type request struct {
	Operation   string
	Endpoint    string
	Branch      string
	Key         string
	Passphrase  string
	Fingerprint string
	Destination string
	Source      string
	Attachments bool
	Expected    string
}

type response struct {
	Revision    string `json:"revision,omitempty"`
	Error       string `json:"error,omitempty"`
	Fingerprint string `json:"fingerprint,omitempty"`
	Omitted     int    `json:"omitted,omitempty"`
	Unchanged   bool   `json:"unchanged,omitempty"`
}

func main() {
	result := run()
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		os.Exit(1)
	}
}

func run() response {
	var input request
	if err := json.NewDecoder(io.LimitReader(os.Stdin, 1024*1024)).Decode(&input); err != nil {
		return response{Error: "无法读取 Git 请求"}
	}
	var snapshotPath string
	switch input.Operation {
	case "", "restore":
		snapshotPath = input.Destination
	case "initialize", "update":
		snapshotPath = input.Source
	default:
		return response{Error: "未知 Git 操作"}
	}
	if !filepath.IsAbs(snapshotPath) {
		return response{Error: "资料库目录必须是绝对路径"}
	}
	work, err := os.MkdirTemp(filepath.Dir(snapshotPath), ".kinen-git-")
	if err != nil {
		return response{Error: "无法创建 Git 缓存目录"}
	}
	defer os.RemoveAll(work)
	repo, err := git.PlainInit(work, true)
	if err != nil {
		return response{Error: "无法初始化 Git 缓存"}
	}
	remote, err := kinen.NewSSHRemote(repo, input.Endpoint, input.Branch, []byte(input.Key), []byte(input.Passphrase), input.Fingerprint)
	if err != nil {
		return response{Error: "SSH 地址、分支、指纹或密钥无效，请检查密钥口令"}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	tip, err := remote.Fetch(ctx)
	if err != nil {
		var rejected *kinen.HostKeyError
		if errors.As(err, &rejected) {
			return response{Fingerprint: rejected.Observed}
		}
		return response{Error: "无法拉取 Git 分支，请检查连接、SSH 权限及仓库地址"}
	}
	if input.Operation == "initialize" || input.Operation == "update" {
		if input.Operation == "initialize" && !tip.IsZero() {
			return response{Error: "目标 Git 分支已有提交。请选择空分支。"}
		}
		var previous *object.Commit
		if input.Operation == "update" {
			if tip.IsZero() || !plumbing.IsHash(input.Expected) || tip.String() != input.Expected {
				return response{Error: "远端分支已变化。当前资料库及远端版本均已保留，请先从 Git 预览远端资料库。"}
			}
			previous, err = repo.CommitObject(tip)
			if err != nil || !sameLibrary(previous, input.Source) {
				return response{Error: "无法确认远端与本机资料库 ID 一致，已停止备份。"}
			}
		}
		author := object.Signature{Name: "Kinen Satsuei", Email: "kinen@users.noreply.invalid", When: time.Now().UTC()}
		candidate, err := remote.CommitSnapshot(ctx, input.Source, tip, author, input.Attachments)
		if err != nil {
			return response{Error: "无法生成资料库备份提交"}
		}
		if previous != nil {
			next, err := repo.CommitObject(candidate.Commit)
			if err != nil {
				return response{Error: "无法读取资料库备份提交"}
			}
			if previous.TreeHash == next.TreeHash {
				return response{Revision: tip.String(), Unchanged: true, Omitted: len(candidate.Omitted)}
			}
		}
		if err := remote.Push(ctx, tip, candidate.Commit); err != nil {
			var rejected *kinen.HostKeyError
			if errors.As(err, &rejected) {
				return response{Fingerprint: rejected.Observed}
			}
			return response{Error: "无法确认备份上传。请检查写入权限，或通过恢复预览查看远端分支。"}
		}
		return response{Revision: candidate.Commit.String(), Omitted: len(candidate.Omitted)}
	}
	if tip.IsZero() {
		return response{Error: "远端分支还没有备份"}
	}
	if err := remote.ExportSnapshot(ctx, tip, input.Destination); err != nil {
		return response{Error: "远端提交无法导出为资料库"}
	}
	return response{Revision: tip.String()}
}

func sameLibrary(previous *object.Commit, source string) bool {
	file, err := previous.File("library.json")
	if err != nil || file.Size < 0 || file.Size > 16*1024*1024 {
		return false
	}
	content, err := file.Contents()
	if err != nil {
		return false
	}
	var remote, local struct{ LibraryID string }
	if err := json.Unmarshal([]byte(content), &remote); err != nil || remote.LibraryID == "" {
		return false
	}
	input, err := os.Open(filepath.Join(source, "library.json"))
	if err != nil {
		return false
	}
	defer input.Close()
	return json.NewDecoder(io.LimitReader(input, 16*1024*1024)).Decode(&local) == nil &&
		strings.EqualFold(remote.LibraryID, local.LibraryID)
}
