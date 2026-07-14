# dump2llm

Dump text files from Git repositories, directories, files, and glob patterns
for use in an LLM chat. Binary and empty files are skipped, and overlapping
inputs are deduplicated.

## Usage

```text
dump2llm [--ignore <path[,path...]>] <inputs...>
```

Examples:

```bash
dump2llm README.md
dump2llm docs/*.md
dump2llm '**/*.py'
dump2llm --ignore 'docs/drafts,*.generated' .
dump2llm https://github.com/example/project.git
```

Directories inside a Git work tree use Git's tracked files plus untracked,
non-ignored files. Other directories are traversed directly, excluding
`.git` directories. Git URLs are cloned into a temporary directory and
removed when the command exits.

Each text file is written to stdout between `<<< FILE: ... >>>` and
`<<< END OF ... >>>` markers. Diagnostics and clone progress go to stderr.
The command never modifies an input repository. An explicit missing file is a
validation error; a glob that matches no files is a successful no-op.
