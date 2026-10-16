# Role behaviors: describe a role's aliases and pickers once (T-34)

**Status:** approved design, 2026-10-16. Builds on the roles v2 design
(`2026-10-05-roles-v2-design.md`).

## Problem

Tools that compete for a role each hand-write the role's aliases in their own flags,
and the copies drift. Both `listing` members define `ls`/`ll`/`la`/`tree`, but they
mean different things: eza's `ll` is long without hidden entries and `la` is long
with them; lsd's `ll` is long, with hidden entries and headers, and its `la` is a
short listing with hidden entries. A user who switches from eza to lsd gets
different commands under the same names.

The `ff` file picker has the same flaw from the other side: it is eza's own
top-level picker, so it exists only when eza is requested, and it lists through
eza even when lsd wins `listing`.

Today `listing` is the only role whose members define aliases. T-35 adds roles that
will compete for aliases too (disk usage, process viewer, JSON), so the mechanism is
general, and `listing` proves it.

## Design

### A role describes its behavior in words

A role in `data/roles.json` may have a `behaviors` block:

- `words`: the role's vocabulary, each word with a one-line meaning.
- `aliases`: alias name → the list of words it means, in the order the flags go.
- `pickers`: declarative pickers (the same fields as a tool's `picker`) whose `list`
  is a list of words instead of a command.

`listing` becomes:

```json
"listing": {
  "kind": "single",
  "exclusive": false,
  "hook": "Initialize-DFRoleListing",
  "reserved": { "env": [], "aliases": [], "code": [] },
  "description": "Lists directory contents. The winner defines ls, ll, la, tree and ff.",
  "behaviors": {
    "words": {
      "color": "color when the terminal supports it",
      "color-always": "always color",
      "icons": "icons when the terminal supports them",
      "icons-always": "always icons",
      "dirs-first": "directories before files",
      "literal": "names unquoted",
      "long": "one row per entry, with details",
      "all": "include hidden entries",
      "git": "git status per entry",
      "tree": "recurse as a tree",
      "one-per-line": "names only, one per line"
    },
    "aliases": {
      "ls":   ["color", "icons", "dirs-first", "literal"],
      "ll":   ["long", "color", "icons", "dirs-first", "git", "literal"],
      "la":   ["long", "all", "color", "icons", "dirs-first", "git", "literal"],
      "tree": ["tree", "literal"]
    },
    "pickers": [
      {
        "alias": "ff",
        "function": "Select-File",
        "list": ["one-per-line", "icons-always", "color-always", "literal"],
        "list_accepts_path": true,
        "preview": "bat --color=always --line-range=:200 {}",
        "preview_window": "right:60%",
        "ansi": true,
        "header": "Select file  [Enter to output path]",
        "action": "output"
      }
    ]
  }
}
```

The meanings are eza's current ones: `ll` is long without hidden entries, `la` is
`ll` with them. lsd's `ll` and `la` change to match (a visible change, recorded under
Changed in the changelog).

For a role with `behaviors`, its reserved aliases are derived: the `aliases` names
plus each picker's `alias`. `reserved.aliases` is left empty in `data/roles.json`,
and `Get-DFRoleDb` fills it from `behaviors` when it loads the file, so every reader
(the role contract, legacy-alias suppression) sees the derived set. Roles without
`behaviors` are unchanged.

### A member maps each word to its own flags

A member's role block gains `flags`: word → array of argument strings. `[]` means
the tool already behaves that way by default.

```json
"listing": {
  "priority": 20,
  "flags": {
    "color": ["--color=auto"], "color-always": ["--color=always"],
    "icons": ["--icons=auto"], "icons-always": ["--icons=always"],
    "dirs-first": ["--group-directories-first"], "literal": ["--no-quotes"],
    "long": ["--long"], "all": ["--all"], "git": ["--git"],
    "tree": ["--tree"], "one-per-line": ["-1"]
  }
}
```

lsd's map is the same with `--icon=` for the icon words and `--literal` for
`literal`. eza's icon flags always carry a value: a bare `--icons` consumes the next
positional argument (`docs/external-dependencies.md`).

A member of a role with `behaviors` may not define the role's aliases itself (in
its role block or its top-level `aliases`), and eza's top-level `picker` (`ff`) is
removed: the role owns it.

### At registration

For each role a tool wins, `Register-DFToolSteps` (where role aliases are applied
today) checks whether the role has `behaviors`:

1. `Get-DFRoleBehaviorAlias -RoleDefinition -Block -Tool` turns each alias's words into
   `{ command, args }`: the command is the tool's executable name without its
   extension (`eza`, `lsd`), the args are each word's flags in the role's order.
   The result goes to `Register-DFToolAliases`, unchanged, so the builtin-safety
   checks behave as before, and an alias the user defines in their profile after
   `Start-DFSession` still wins.
2. `Get-DFRolePicker -RoleDefinition -Block -Tool` does the same for each role picker,
   replacing `list` with `"<command> <flags>"`, and passes it to
   `Set-DFPickerFunction`, so `list_accepts_path`, preview, header and action work
   as for any declarative picker.

A tool that loses the role gets none of these, as role aliases work today. The cost
is a few string joins per won role, from records already loaded.

Both functions live in `Private/` (startup core) and return result objects.

### When something is missing

- **Schema** (`Test-DFToolSchema`): `flags`, when present in a role block, must be an
  object of word → array of strings. The schema checks one record and can't see
  `data/roles.json`, so the role-aware rules (no hand-written aliases for a
  behaviors role, every word mapped) are the role contract test's, and at runtime a
  behaviors role's hand-written block aliases are skipped with a verbose message.
- **A member lacks a word the role uses:** the alias or picker is built without
  that word's flags, and the tool's status notes it once, e.g.
  `listing: no flag for 'git' (ll, la)`. DotForge's own tools can't reach this: the
  role contract test fails first.
- **A member maps a word the role doesn't define:** a role contract failure for
  DotForge's tools; ignored at runtime.
- **A legacy record** (v1 `role` string): `behaviors` doesn't apply; it keeps
  today's behavior.

## Tests

- `tests/Get-DFRoleBehaviorAlias.Tests.ps1`: words become args in the role's order;
  `[]` adds nothing; a missing word is skipped and noted; a picker's list is built
  from the winner's flags.
- `tests/Roles.Contract.Tests.ps1`: every member of a role with `behaviors` maps
  every word the role uses, and only those words; no member defines the role's
  aliases by hand; the derived reserved set is the alias names plus picker aliases.
- `tests/Roles.Registration.Tests.ps1`: with eza and lsd requested, the winner gets
  `ls`/`ll`/`la`/`tree`/`ff` from its flags and the loser none; `Defaults = @{
  listing = 'lsd' }` flips it; lsd alone gets `ff` listing through lsd.
- A test spells out eza's and lsd's exact args per alias, so a mapping change is a
  deliberate edit.
- Alias names are unchanged (`ls`, `ll`, `la`, `tree`, `ff`), already cleared by the
  builtin-safety policy.

## Docs

- `docs/guide/writing-a-tool.md`, "Joining a role": mapping a role's words, with lsd
  as the example.
- `docs/superpowers/specs/2026-10-05-roles-v2-design.md`: a short addendum pointing
  here.
- `CLAUDE.md`, the `roles` schema bullet.
- `docs/guide/tools.md`: what `ls`, `ll`, `la`, `tree` and `ff` mean.
- `CHANGELOG.md`: Changed (lsd's `ll`/`la`), Added (role behaviors; `ff` through the
  listing winner).
- Regenerate the tool registry, the reference and the core bundle.

## Out of scope

- Role behaviors for other roles: T-35 adds them as it onboards tools.
- Per-user remapping of words (a user who wants `ll` to include hidden entries
  defines their own `ll` in their profile after `Start-DFSession`).
