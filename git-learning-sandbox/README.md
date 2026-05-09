# Git Learning Sandbox

这个目录是 Git 练习仓库，路径是：

```bash
/home/ps/dcr/claudecode/claudecode_sourcecode1/git-learning-sandbox
```

外层 `claudecode_sourcecode1` 也是一个 Git 仓库，所以练习时一定先进入这个目录。

## 本轮目标

重新完整练一遍从“修改文件”到“推送远程”的流程：

```text
修改文件 -> git status -> git diff -> git add -> git commit -> git push
```

这轮练习只做到 `push`。冲突、分支、pull request 后面再学。

## 当前起点

我已经确认当前本地仓库和模拟远程是同步的：

```bash
git status --short --branch
```

当前输出：

```text
## main...practice-origin/main
 M GIT_LESSON_CN.md
 M README.md
```

解释：

- `main...practice-origin/main`：本地 `main` 正在跟踪远程 `practice-origin/main`。
- 没有 `[ahead 1]`：说明上一次个人提交已经推送成功。
- `M README.md` 和 `M GIT_LESSON_CN.md`：这两个教学文档正在被重新编写，还没有提交。

当前远程：

```bash
git remote -v
```

输出：

```text
practice-origin	/home/ps/dcr/claudecode/claudecode_sourcecode1/git-learning-remote.git (fetch)
practice-origin	/home/ps/dcr/claudecode/claudecode_sourcecode1/git-learning-remote.git (push)
```

这里的 `practice-origin` 是本地模拟的 GitHub 远程仓库。

## 第 1 步：进入练习仓库

在终端运行：

```bash
cd /home/ps/dcr/claudecode/claudecode_sourcecode1/git-learning-sandbox
```

确认位置：

```bash
pwd
```

你应该看到：

```text
/home/ps/dcr/claudecode/claudecode_sourcecode1/git-learning-sandbox
```

## 第 2 步：查看当前状态

运行：

```bash
git status --short --branch
```

你需要先看懂这行：

```text
## main...practice-origin/main
```

含义：

- `main`：你当前在本地 `main` 分支。
- `practice-origin/main`：远程仓库里的 `main` 分支。
- 如果看到 `[ahead 1]`：本地有提交还没 push。
- 如果看到 `[behind 1]`：远程有提交你还没 pull。
- 如果只看到 `## main...practice-origin/main`：本地和远程提交同步。

## 第 3 步：修改一个文件

打开 `notes.md`，在最后增加一行，例如：

```markdown
- Second practice: I am learning the full Git add, commit, and push flow.
```

保存文件。

## 第 4 步：查看 Git 发现了什么

运行：

```bash
git status
```

你应该看到 `notes.md` 出现在 modified 状态里。

再运行：

```bash
git diff notes.md
```

你会看到类似：

```diff
+- Second practice: I am learning the full Git add, commit, and push flow.
```

说明：

- `+` 开头表示新增内容。
- `-` 开头表示删除内容。
- 如果进入 `(END)` 页面，按 `q` 退出。

## 第 5 步：放进暂存区

只暂存 `notes.md`：

```bash
git add notes.md
```

再看状态：

```bash
git status
```

你应该看到 `notes.md` 变成准备提交的状态。

如果想看暂存区内容：

```bash
git diff --cached
```

## 第 6 步：创建提交

运行：

```bash
git commit -m "Practice Git add commit push flow"
```

提交成功后看历史：

```bash
git log --oneline --graph --decorate --all --max-count=8
```

你应该看到最上面多了一条新提交。

## 第 7 步：推送到远程

提交后运行：

```bash
git status --short --branch
```

如果看到：

```text
## main...practice-origin/main [ahead 1]
```

说明本地比远程多 1 个提交，可以推送：

```bash
git push
```

推送后再次确认：

```bash
git status --short --branch
```

如果 `[ahead 1]` 消失，说明推送成功。

## 终端记录模板

把你本轮终端输出记录在这里，方便之后复盘。

```text
$ cd /home/ps/dcr/claudecode/claudecode_sourcecode1/git-learning-sandbox

$ git status --short --branch

$ git diff notes.md

$ git add notes.md

$ git status

$ git diff --cached

$ git commit -m "Practice Git add commit push flow"

$ git status --short --branch

$ git push

$ git status --short --branch
```

