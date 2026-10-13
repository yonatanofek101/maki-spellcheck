# maki-spellcheck

Spell checking for [Maki](https://github.com/tontinton/maki), using the macOS
system spell checker (`NSSpellChecker`). macOS only.

- **Autocorrect as you type** in the chat input. When you finish a word, a
  confident typo is replaced (`teh` becomes `the`) and the status bar shows
  what changed.
- **`spell_check` tool** the agent can run on text or a file (docs, commit
  messages, UI strings). Code spans, fenced code, URLs, paths, emails and
  identifiers are skipped.
- **`/spell <text>`** checks some text. **`/spell on`** / **`/spell off`**
  toggles autocorrect.

## Install

Requires Maki 0.6.3 or later.

1. Add this line to `~/.config/maki/init.lua`:

   ```lua
   maki.pack.add({ "https://github.com/yonatanofek101/maki-spellcheck" })
   ```

2. Restart Maki and approve the install and its permissions: `fs_read` (your
   word list) and `run` (`osascript`, which talks to the macOS spell checker).

Update with `/packupdate maki-spellcheck`.

## Autocorrect

- Only words the macOS autocorrect is confident about are replaced. Words with
  no clear fix are left alone.
- Undo a wrong correction by deleting it and typing your word again. That word
  is then left alone for the rest of the Maki session.
- Skipped: text inside backticks, slash commands, paths, URLs, camelCase,
  ACRONYMS, words with digits or underscores, and pasted text.

## Your own words

List words that should never be flagged in `spell_words.txt` in your Maki config
directory (normally `~/.config/maki/spell_words.txt`), one per line. Lines
starting with `#` are ignored.

## Options

Pass options with a custom loader:

```lua
maki.pack.add({ "https://github.com/yonatanofek101/maki-spellcheck" }, {
  load = function()
    require("spellcheck").setup({
      language = "en_GB",
      ignore = { "kubectl", "tilt" },
    })
  end,
})
```

| Option | Default | Meaning |
| --- | --- | --- |
| `autocorrect` | `true` | Correct words as you type |
| `language` | `"en"` | macOS spell checker language |
| `max_suggestions` | `5` | Suggestions per typo for the tool and `/spell` |
| `ignore` | `{}` | Extra words to accept |
| `words_file` | `<config>/spell_words.txt` | Path of your word list |
| `check_key` | `false` | Key that checks the chat input, e.g. `"<F7>"` |
| `fix_key` | `false` | Key that fixes every typo in the chat input |
