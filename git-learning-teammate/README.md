# Git Learning Sandbox

这是一个专门用来学习 Git 的虚拟项目，和外层 `claudecode_sourcecode1`
源码仓库相互独立。

## 你先记住的核心概念

- `working tree`：你正在编辑的文件目录。
- `staging area`：准备放进下一次提交的临时区域，也叫暂存区。
- `commit`：一次可回退、可对比的项目快照。
- `branch`：一条开发线。常见做法是在新分支开发功能，再合并回 `main`。
- `remote`：远程仓库，比如 GitHub 上的仓库。
- `pull`：从远程拿最新代码并合并到本地。
- `push`：把本地提交上传到远程。

## 最常用的日常流程

```bash
git status
git add .
git commit -m "Describe what changed"
git pull --rebase origin main
git push origin main
```

## 推荐练习顺序

1. 修改 `notes.md`。
2. 用 `git status` 看 Git 发现了什么。
3. 用 `git diff` 看具体修改。
4. 用 `git add notes.md` 放入暂存区。
5. 用 `git commit -m "Update notes"` 创建提交。
6. 用 `git log --oneline --graph --decorate --all` 看历史。

## 接入真实 GitHub 仓库

先在 GitHub 网站上新建一个空仓库，例如：

```text
https://github.com/YOUR_NAME/git-learning-sandbox.git
```

然后在本目录运行：

```bash
git remote add origin https://github.com/YOUR_NAME/git-learning-sandbox.git
git branch -M main
git push -u origin main
```

后续日常同步：

```bash
git pull --rebase origin main
git push
```

