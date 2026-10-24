# Tools

Tools that DotForge manages. For every tool DotForge provides the following:

- Install/Uninstall/Update
- Configure to use XDG directory structure
- Set any base or recommended setting defaults
- Theme to match all other themeable tools
- Provide any common or useful aliases
- Provide pickers where it makes sense to improve ability to navigate, search, preview large lists, etc.
- Provide Command line completions
- Manage Tool Roles where there are multiple tools that provide the same function, allow the user to select the one that is the default provider of that function.
- Tell the user about any manual setup step once, at first setup (`setup.notes`)

Synced with the repo on 2026-10-17 (main `e9e7e15`): 62 tools in `Tools/`, 27 roles in
`data/roles.json`. The backlog IDs (`T-35`, …) are in `TODO.md`. T-35 is the umbrella item for
onboarding tools into roles, one small spec per batch.

## Tool Collections (Don't change unless explicitly agreed upon)

Collections of tools that can be installed, managed, uninstalled together as a group. These are just a few random brainstormed groups currently. Still TODO.

- Core
- Required
- Recommended
- File Tools
- Dev Tools
- Javascript Dev
- Python Dev
- Admin/Management Tools
- Network Tools

### Groups that exist today (`data/groups.json`, used as `+name` in `Tools`)

| Group            | Tools                                                                                           |
| ---------------- | ----------------------------------------------------------------------------------------------- |
| core             | psreadline, PSFzf, fzf, eza, bat, fd, ripgrep, zoxide, carapace, less, fastfetch, smartmontools |
| fuzzy            | fzf, skim, television, peco, gum                                                                |
| prompt           | starship                                                                                        |
| git              | delta, gh, lazygit                                                                              |
| dev-tools        | jq, micro, mise, chezmoi                                                                        |
| javascript-dev   | fnm, node, npm                                                                                  |
| python-dev       | uv, python, pip, pipx                                                                           |
| rust-dev         | rustup, cargo                                                                                   |
| admin-tools      | gsudo, procs, fastfetch, curl, wget                                                             |
| markdown         | glow                                                                                            |
| fonts            | NerdFonts, GoogleFonts, fontget, gfcli                                                          |
| package-managers | scoop, winget                                                                                   |

Not yet a group: Required, Recommended, File Tools, Network Tools.

## Tool Roles

**Single** roles have one winner (`Defaults`, else the highest priority), which gets the role's
aliases, variables and hook. **Category** roles only group tools that do the same job.

### Done (in `data/roles.json`)

**Ref** says `done <date>` when every member has the whole tool contract and the role is filled;
otherwise **Still to add** lists the missing tools and the gaps in the current members.

| Role                       | Kind     | Members today                              | Still to add                                                                                                         | Ref                                                                                                   |
| -------------------------- | -------- | ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| pager                      | single   | less, moor, ov (fallback `more`)           | bat as pager?                                                                                                        | done 2026-10-16                                                                                       |
| picker                     | single   | fzf, skim                                  |                                                                                                                      | done 2026-10-17                                                                                       |
| fuzzy-finder               | category | fzf, skim, television, peco, gum           |                                                                                                                      | done 2026-10-17                                                                                       |
| history-search (Ctrl+R)    | single   | PSFzf, television, fzf, skim               | atuin, mcfly                                                                                                         | T-67                                                                                                  |
| path-insert (Ctrl+T)       | single   | PSFzf, television, fzf, skim               |                                                                                                                      | done 2026-10-17                                                                                       |
| process-viewer             | category | procs, btop, bottom, glances, ntop, pstop  | instant replay (T-72)                                                                                                | done 2026-10-17                                                                                       |
| disk-usage                 | category | dust, dua, gdu, duf                        |                                                                                                                      | done 2026-10-17                                                                                       |
| font-installer             | category | NerdFonts, GoogleFonts, fontget, gfcli     |                                                                                                                      | done 2026-10-23 (`Install-DFNerdFont` installs a first Nerd Font; no font = icons off, `NerdFont`)    |
| directory-jump (Alt+C)     | single   | fzf, skim, broot                           | yazi, superfile, lf (file-manager batch)                                                                             | done 2026-10-17                                                                                       |
| listing                    | single   | eza, lsd                                   |                                                                                                                      | done 2026-10-16 (T-34, role behaviors)                                                                |
| package-manager            | single   | scoop, winget, choco                       | gaps: winget search picker, choco XDG/pickers (T-47); update/remove polish (T-58)                                    | T-47                                                                                                  |
| project-env                | single   | direnv, mise, ps-dotenv                    | more env tools                                                                                                       | T-36                                                                                                  |
| navigation                 | single   | zoxide                                     | z?                                                                                                                   |                                                                                                       |
| grep                       | category | ripgrep                                    | grep                                                                                                                 |                                                                                                       |
| file-search                | category | fd                                         | find / findutils                                                                                                     |                                                                                                       |
| prompt                     | single   | oh-my-posh, starship                       | gap: `oh-my-posh init` runs every start (T-66)                                                                       | done 2026-10-17 (both follow `Theme`, live)                                                           |
| completion                 | category | psreadline, carapace, inshellisense, PSFzf | gaps: carapace's colors don't follow `Theme` (`carapace --style`); carapace could load after the first prompt (T-46) |                                                                                                       |
| tab-completion             | single   | carapace, inshellisense, PSFzf             | gaps: same as completion (carapace colors, T-46)                                                                     |                                                                                                       |
| elevator                   | category | gsudo                                      |                                                                                                                      | done 2026-10-17 (Windows `sudo` is used by DotForge's elevation, not a separate tool)                 |
| url-fetch                  | category | curl, wget                                 | httpie, xh, curlie, aria2                                                                                            | T-35                                                                                                  |
| diff                       | single   | delta                                      | difftastic, livediff, winmerge, meld, kdiff3                                                                         |                                                                                                       |
| system-info                | category | fastfetch                                  | winfetch, neofetch                                                                                                   |                                                                                                       |
| editor                     | single   | micro                                      | nano (tool exists, not in role), vim, neovim, edit, VS Code; set `EDITOR`/`VISUAL`                                   | T-35                                                                                                  |
| markdown-viewer            | category | glow, mdcat, mdv                           | frogmouth; promote to single once something uses a winner                                                            | T-35                                                                                                  |
| js-runtime                 | category | node, bun                                  |                                                                                                                      | done 2026-10-17 (bun under XDG; node's REPL history moves with npms record)                           |
| js-package-manager         | category | npm, pnpm, bun                             |                                                                                                                      | done 2026-10-17 (pnpm and bun under XDG; `Select-NpmScript` runs scripts with each project's manager) |
| python-runtime             | category | python                                     |                                                                                                                      | done 2026-10-17 (REPL history under XDG)                                                              |
| python-package-manager     | category | pip, pipx, uv                              |                                                                                                                      | done 2026-10-17 (pip and pipx under XDG)                                                              |
| rust-package-manager       | category | cargo                                      |                                                                                                                      | done 2026-10-11 (cargo installs; `CARGO_HOME` relocated with rustup; carapace completes it)           |
| powershell-package-manager | category | psresource                                 | PowerShellGet; gaps: no installed-module picker                                                                      |                                                                                                       |
| version-manager            | category | fnm, mise, uv, rustup, pymanager           | volta, asdf, nvm                                                                                                     |                                                                                                       |

### Planned (no role yet)

| Role                 | Candidates                                                              | Ref  |
| -------------------- | ----------------------------------------------------------------------- | ---- |
| file-manager         | yazi, superfile, lf, broot, midnight commander, vifm, ranger            | T-35 |
| git-tui              | lazygit (tool exists), gitui                                            | T-35 |
| json                 | jq (tool exists), jaq, gojq, fx, jless, jid; yq, dasel                  | T-35 |
| dotfiles             | chezmoi (tool exists), yadm, stow                                       | T-35 |
| quick-help           | tldr, tealdeer (two clients for the tldr pages), cheat.sh (cht)         | T-35 |
| secrets              | bitwarden (tool exists), 1Password, pass                                | T-35 |
| replace              | sd                                                                      | T-35 |
| watch                | watchexec                                                               | T-35 |
| code-stats           | tokei, scc                                                              | T-35 |
| cat alternative      | bat (tool exists, no role)                                              |      |
| terminal multiplexer | zellij, psmux, tmux                                                     |      |
| terminal emulator    | Windows Terminal, Intelligent Terminal, Warp, Alacritty, Tabby, WezTerm |      |
| AI harness           | Claude, Codex, Antigravity CLI, Pi, Oh-my-pi, OpenCode                  |      |
| AI orchestrator      | Herdr                                                                   |      |
| library managers     | Ruby: gem; C/C++: vcpkg (tool exists), conan; Perl: cpanm, carton       |      |

NOTE: configure CLAUDE_CODE_GIT_BASH_PATH when setting up Claude Code.

## Tools

### Done (`Tools/*.json`)

bat, bitwarden, broot, bun, carapace, cargo, chezmoi, choco, curl, delta, direnv, docker, eza,
fastfetch, fd, fnm, fzf, gh, glow, gsudo, gum, inshellisense, jq, lazygit, less, lsd, mdcat, mdv,
micro, mise, moor, nano, node, npm, oh-my-posh, ov, peco, pip, pipx, pnpm, posh-git, procs,
ps-dotenv, PSFzf, psreadline, psresource, pymanager, python, ripgrep, rustup, scoop, skim,
smartmontools, starship, television, Terminal-Icons, uv, vcpkg, vivid, wget, winget, zoxide

Gaps among these:

- **broot** is done (directory-jump, 2026-10-17); it may also join `file-manager` when that role exists.
- **nano** has a record but isn't in the editor role.
- **lazygit**, **procs**, **jq**, **chezmoi** and **bitwarden** have records, but their planned roles don't exist yet.
- **bat** has no role.
- Only 3 tools have conformance probes (T-25), and setup notes still need a review for every tool (T-69).
- More configs are wanted for ssh, choco, winget and dotnet (T-47).

### Remaining, by planned role

- **history-search:** atuin, mcfly (T-67)
- **file-manager / directory-jump:** yazi, superfile, lf, mc (midnight commander), ranger, vifm
- **url-fetch:** aria2, httpie, xh, curlie
- **git-tui:** gitui
- **process-viewer:** done (htop is pstop's link on Windows; top has no Windows build)
- **disk-usage:** done (ncdu has no Windows build; gdu is its port)
- **json:** jaq, gojq, fx, jless, jid, jc, yq, dasel, xidel
- **dotfiles:** yadm, stow
- **quick-help:** tldr, tealdeer (two clients for the same tldr pages), cheat.sh (cht)
- **secrets:** pass, 1Password CLI
- **editor:** vim, nvim
- **system-info:** winfetch, neofetch
- **markdown-viewer:** frogmouth, nap?, qmd?
- **version-manager:** asdf, nvm, volta
- **multiplexer:** tmux / psmux, zellij
- **diff:** difftastic, diffutils
- **replace / watch / code-stats:** sd, watchexec, tokei, scc
- **grep / file-search:** grep, findutils (rust rewrite), locate / mlocate, pseverything

### Remaining, no role (single tools)

- **Archives:** 7zip, ouch, tar, zip/unzip
- **Network:** dig, nc, nmap, ngrep, bandwhich, netstat, psnet, tcpdump, ip, iptables, ssh, scp, rsync, bind (network utils), idna
- **Files and binary:** coreutils (Microsoft: cat, head, tail, sort, tr, uniq, xargs, sed, df, du, tac, paste, …), hexyl, hexdump, xxd, jdupes, detox, exiftool, rip, mkcd
- **Forensics / disk:** dc3dd, dcfldd, foremost
- **Build:** cmake, make, ctags
- **Dev environments:** devenv.sh, nix
- **Shell extras:** thefuck, yasb, nircmd, sfsu, gpg4win, sudo (Windows)
- **Fonts:** done 2026-10-23 (`font-installer`, `+fonts`, `Install-DFNerdFont`; the scoop `nerd-fonts` bucket is documented in `docs/guide/fonts.md`, not a tool). Not onboarded: winget's `DEVCOM.*NerdFont` and choco's packages install machine-wide with admin rights.
- **Media / docs:** mpv, yt-dlp, pandoc, zbar
- **Fun:** cowsay, fortune, lolcat
- **Other:** git, sysinternals, lsof, pkill, free, uptime, lsix, yay

### Unclear (check before adding)

- **Linux-only, or no native Windows build:** iptables, ip, yay, lsix, locate/mlocate, free, uptime, pkill, lsof, tcpdump, ncdu, htop (pstop installs an htop link).
- **Covered elsewhere:** `z` and zoxide (zoxide is done), `rg` and ripgrep, `tmux` and psmux.
