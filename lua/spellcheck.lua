local M = {}

local CHUNK_BYTES = 100000
local MAX_TEXT_BYTES = 2000000
local JOB_TIMEOUT_MS = 20000

-- NSSpellChecker speaks UTF-16 offsets; convert to UTF-8 bytes here so Lua can slice the original text.
local JXA = [[
ObjC.import('AppKit');
function run(argv) {
  const js = argv[0];
  const sc = $.NSSpellChecker.sharedSpellChecker;
  sc.automaticallyIdentifiesLanguages = false;
  sc.setLanguage(argv[1]);
  const maxGuesses = Number(argv[2]);
  const s = $(js);
  const len = Number(s.length);
  const utf8Len = (str) => { try { return unescape(encodeURIComponent(str)).length; } catch (e) { return str.length; } };
  const out = [];
  let start = 0, lastLoc = 0, lastBytes = 0;
  while (start < len) {
    const r = sc.checkSpellingOfStringStartingAt(s, start);
    const loc = Number(r.location), n = Number(r.length);
    if (n === 0 || loc < start || loc >= len) break;
    const g = sc.guessesForWordRangeInStringLanguageInSpellDocumentWithTag(r, s, $(), 0);
    const guesses = [];
    if (g && !g.isNil()) for (let i = 0; i < Math.min(Number(g.count), maxGuesses); i++) guesses.push(g.objectAtIndex(i).js);
    const word = js.slice(loc, loc + n);
    lastBytes += utf8Len(js.slice(lastLoc, loc));
    lastLoc = loc;
    out.push({ word: word, start: lastBytes, stop: lastBytes + utf8Len(word), suggestions: guesses });
    start = loc + n;
  }
  return JSON.stringify(out);
}
]]

local JXA_CORRECT = [[
ObjC.import('AppKit');
function run(argv) {
  const sc = $.NSSpellChecker.sharedSpellChecker;
  const s = $(argv[0]), lang = $(argv[1]);
  const r = sc.checkSpellingOfStringStartingAtLanguageWrapInSpellDocumentWithTagWordCount(s, 0, lang, false, 0, null);
  if (Number(r.length) === 0) return '';
  const c = sc.correctionForWordRangeInStringLanguageInSpellDocumentWithTag(r, s, lang, 0);
  return (c && !c.isNil()) ? c.js : '';
}
]]

local opts = {
  language = "en",
  max_suggestions = 5,
  ignore = {},
  words_file = nil,
  autocorrect = true,
  check_key = false,
  fix_key = false,
}

local function blank(s)
  return (s:gsub("[^\n]", " "))
end

local function mask(text)
  text = text:gsub("```.-```", blank)
  text = text:gsub("`[^`\n]*`", blank)
  text = text:gsub("%a[%w+.%-]*://%S+", blank)
  text = text:gsub("[%w._%%+%-]+@[%w%-]+%.[%w.%-]+", blank)
  text = text:gsub("%S*[/\\]%S*", blank)
  text = text:gsub("[%w_%-]+%.%a%a%a?%a?%f[^%w]", blank)
  text = text:gsub("[%w_]+", function(tok)
    if tok:find("[%d_]") or tok:sub(2):find("%u") then
      return blank(tok)
    end
  end)
  return text
end

local function words_path()
  return opts.words_file or maki.fs.joinpath(maki.env.config_dir(), "spell_words.txt")
end

local function load_ignored()
  local set = {}
  for _, w in ipairs(opts.ignore) do
    set[w:lower()] = true
  end
  local content = maki.fs.read(words_path())
  if content then
    for line in content:gmatch("[^\r\n]+") do
      local w = line:match("^%s*([^#%s][^%s]*)")
      if w then
        set[w:lower()] = true
      end
    end
  end
  return set
end

local function check_chunk(chunk, base)
  local id, err = maki.fn.jobstart(
    { "osascript", "-l", "JavaScript", "-e", JXA, "--", chunk, opts.language, tostring(opts.max_suggestions) }
  )
  if not id then
    return nil, "could not start osascript: " .. tostring(err)
  end
  local res, werr = maki.fn.jobwait(id, JOB_TIMEOUT_MS)
  if not res then
    maki.fn.jobstop(id)
    return nil, "spell checker did not answer: " .. tostring(werr)
  end
  if res.exit_code ~= 0 then
    return nil, "spell checker failed: " .. (res.stderr or "")
  end
  local ok, issues = pcall(maki.json.decode, res.stdout)
  if not ok or type(issues) ~= "table" then
    return nil, "bad spell checker output: " .. tostring(res.stdout)
  end
  for _, it in ipairs(issues) do
    it.start = it.start + base
    it.stop = it.stop + base
  end
  return issues
end

local function correct_word(word)
  local id, err = maki.fn.jobstart({ "osascript", "-l", "JavaScript", "-e", JXA_CORRECT, "--", word, opts.language })
  if not id then
    return nil, err
  end
  local res, werr = maki.fn.jobwait(id, JOB_TIMEOUT_MS)
  if not res then
    maki.fn.jobstop(id)
    return nil, werr
  end
  if res.exit_code ~= 0 then
    return nil, res.stderr
  end
  local fixed = (res.stdout or ""):match("^%s*(.-)%s*$")
  if fixed == "" or fixed == word then
    return nil
  end
  return fixed
end

function M.check(text)
  if maki.fn.executable("osascript") ~= 1 then
    return nil, "spellcheck needs macOS (osascript / NSSpellChecker)"
  end
  if #text > MAX_TEXT_BYTES then
    return nil, ("text is %d bytes, limit is %d"):format(#text, MAX_TEXT_BYTES)
  end
  local masked = mask(text)
  local ignored = load_ignored()
  local all = {}
  local pos = 1
  while pos <= #masked do
    local stop = math.min(pos + CHUNK_BYTES - 1, #masked)
    if stop < #masked then
      local nl = masked:sub(pos, stop):match(".*()\n")
      if nl then
        stop = pos + nl - 1
      end
    end
    local chunk = masked:sub(pos, stop)
    if chunk:find("%a") then
      local issues, err = check_chunk(chunk, pos - 1)
      if not issues then
        return nil, err
      end
      for _, it in ipairs(issues) do
        if not ignored[it.word:lower()] then
          all[#all + 1] = it
        end
      end
    end
    pos = stop + 1
  end
  return all
end

local function line_col(text, byte0)
  local before = text:sub(1, byte0)
  local line = select(2, before:gsub("\n", "")) + 1
  local col = #before:match("[^\n]*$") + 1
  return line, col
end

local function format_issues(text, issues, limit)
  local out = {}
  for i, it in ipairs(issues) do
    if i > limit then
      out[#out + 1] = ("... %d more not shown"):format(#issues - limit)
      break
    end
    local line, col = line_col(text, it.start)
    local sugg = #it.suggestions > 0 and table.concat(it.suggestions, ", ") or "(no suggestions)"
    out[#out + 1] = ("L%d:%d %s -> %s"):format(line, col, it.word, sugg)
  end
  return table.concat(out, "\n")
end

local function short_summary(issues)
  local parts = {}
  for i, it in ipairs(issues) do
    if i > 6 then
      parts[#parts + 1] = "..."
      break
    end
    parts[#parts + 1] = it.word .. (it.suggestions[1] and ("→" .. it.suggestions[1]) or "?")
  end
  return ("%d typo%s: %s"):format(#issues, #issues == 1 and "" or "s", table.concat(parts, ", "))
end

local function apply_fixes(text, issues, cursor)
  local pieces, last, new_cursor, fixed = {}, 1, cursor, 0
  for _, it in ipairs(issues) do
    local repl = it.suggestions[1]
    if repl then
      pieces[#pieces + 1] = text:sub(last, it.start)
      pieces[#pieces + 1] = repl
      last = it.stop + 1
      fixed = fixed + 1
      if it.stop <= cursor then
        new_cursor = new_cursor + #repl - (it.stop - it.start)
      end
    end
  end
  pieces[#pieces + 1] = text:sub(last)
  return table.concat(pieces), new_cursor, fixed
end

local function with_input(fn)
  maki.async.run(function()
    local st, err = maki.ui.input()
    if not st then
      maki.notify("spellcheck: " .. tostring(err), "error")
      return
    end
    if not st.text:find("%a") then
      maki.ui.flash("spellcheck: input is empty")
      return
    end
    local issues, cerr = M.check(st.text)
    if not issues then
      maki.notify("spellcheck: " .. cerr, "error")
      return
    end
    fn(st, issues)
  end)
end

local function check_input()
  with_input(function(_, issues)
    maki.ui.flash(#issues == 0 and "spellcheck: no typos" or short_summary(issues))
  end)
end

local function fix_input()
  with_input(function(st, issues)
    if #issues == 0 then
      maki.ui.flash("spellcheck: no typos")
      return
    end
    local new_text, new_cursor, fixed = apply_fixes(st.text, issues, st.cursor)
    if fixed == 0 then
      maki.ui.flash(short_summary(issues) .. " (nothing to auto-fix)")
      return
    end
    local ok, err = maki.ui.input_edit({
      start = 0,
      stop = #st.text,
      text = new_text,
      cursor = new_cursor,
      version = st.version,
      session_id = st.session_id,
    })
    if not ok then
      maki.notify("spellcheck: input changed, try again (" .. tostring(err) .. ")", "warn")
      return
    end
    maki.ui.flash(("spellcheck: fixed %d of %d"):format(fixed, #issues))
  end)
end

local prev_len = {}
local last_fix = {}
local own_edit = {}
local rejected = {}

local function learn_word(word)
  local key = word:lower()
  rejected[key] = true
  if load_ignored()[key] then
    return true
  end
  local path = words_path()
  local existing = maki.fs.read(path) or ""
  local sep = (existing ~= "" and not existing:find("\n$")) and "\n" or ""
  local ok, err = maki.fs.append(path, sep .. word .. "\n")
  if not ok then
    return nil, err
  end
  return true
end

local function forget_word(word)
  local key = word:lower()
  rejected[key] = nil
  local path = words_path()
  local existing = maki.fs.read(path)
  if not existing then
    return false
  end
  local kept, removed = {}, false
  for line in existing:gmatch("[^\n]*") do
    local w = line:match("^%s*([^#%s][^%s]*)")
    if w and w:lower() == key then
      removed = true
    elseif line ~= "" then
      kept[#kept + 1] = line
    end
  end
  if not removed then
    return false
  end
  local ok, err = maki.fs.write(path, #kept > 0 and table.concat(kept, "\n") .. "\n" or "")
  if not ok then
    return nil, err
  end
  return true
end

local function learn_rejected(word)
  maki.async.run(function()
    local ok, err = learn_word(word)
    if ok then
      maki.ui.flash(("spellcheck: learned %q, won't correct it again"):format(word))
    else
      maki.log.warn("spellcheck: could not save word: " .. tostring(err))
      maki.ui.flash(("spellcheck: kept %q for this session"):format(word))
    end
  end)
end

local function user_reverted(text, fix)
  local stop = fix.start + #fix.from
  return text:sub(fix.start, stop - 1) == fix.from
    and not text:sub(stop, stop):find("[%a']")
    and text:sub(fix.start, fix.start + #fix.to - 1) ~= fix.to
end

local function word_just_finished(text, cursor)
  local before = text:sub(1, cursor)
  if not before:find("[%s%.,;:!%?%)\"]$") then
    return nil
  end
  if select(2, before:gsub("`", "")) % 2 == 1 or before:find("^%s*/") then
    return nil
  end
  local head = before:sub(1, -2)
  local tok_start, tok = head:match("()(%S*)$")
  local lead, word = tok:match("^([\"'%(%[]?)(%a[%a']*)$")
  if not word or #word < 2 or word:sub(2):find("%u") then
    return nil
  end
  word = word:gsub("'+$", "")
  return word, tok_start + #lead
end

local function autocorrect_word(sid, word, start)
  local key = word:lower()
  if rejected[key] or load_ignored()[key] then
    return
  end
  maki.async.run(function()
    local fixed, err = correct_word(word)
    if err then
      maki.log.warn("spellcheck autocorrect: " .. tostring(err))
    end
    if not fixed then
      return
    end
    local st = maki.ui.input()
    if not st or st.session_id ~= sid or st.text:sub(start, start + #word - 1) ~= word then
      return
    end
    local stop = start - 1 + #word
    own_edit[sid] = st.text:sub(1, start - 1) .. fixed .. st.text:sub(stop + 1)
    local ok = maki.ui.input_edit({
      start = start - 1,
      stop = stop,
      text = fixed,
      cursor = st.cursor >= stop and st.cursor + #fixed - #word or st.cursor,
      version = st.version,
      session_id = st.session_id,
    })
    if ok then
      last_fix[sid] = { from = word, to = fixed, start = start }
      maki.ui.flash(("spellcheck: %s → %s"):format(word, fixed))
    end
  end)
end

local function on_input_changed(ev)
  local d = ev.data
  if not d or d.cursor_only then
    return
  end
  local sid = d.session_id
  local grew = #d.text - (prev_len[sid] or 0)
  prev_len[sid] = #d.text
  if d.text == own_edit[sid] then
    own_edit[sid] = nil
    return
  end
  if d.text == "" then
    last_fix[sid] = nil
    return
  end
  local fix = last_fix[sid]
  if fix and user_reverted(d.text, fix) then
    last_fix[sid] = nil
    learn_rejected(fix.from)
    return
  end
  if grew < 1 or grew > 2 then
    return
  end
  local word, start = word_just_finished(d.text, d.cursor)
  if word then
    autocorrect_word(sid, word, start)
  end
end

local function register()
  maki.api.register_tool({
    name = "spell_check",
    kind = "read",
    description = [[Spell check English prose with the macOS system spell checker.

- Pass `text`, or `path` to check a file (markdown, docs, commit messages, UI strings).
- Code spans, fenced code, URLs, paths, emails and identifiers (camelCase, snake_case, ACRONYMS, words with digits) are skipped.
- Returns one line per suspected typo: `L<line>:<col> <word> -> <suggestions>`. Suggestions are guesses; judge them in context before editing.]],
    schema = {
      type = "object",
      properties = {
        text = { type = "string", description = "Text to check" },
        path = { type = "string", description = "File to check instead of text" },
        max_issues = { type = "integer", description = "Max issues to list (default 100)" },
      },
    },
    handler = function(input)
      local text = input.text
      if input.path then
        local content, err = maki.fs.read(input.path)
        if not content then
          return { llm_output = "error: " .. tostring(err), is_error = true }
        end
        text = content
      end
      if not text then
        return { llm_output = "error: pass text or path", is_error = true }
      end
      local issues, err = M.check(text)
      if not issues then
        return { llm_output = "error: " .. err, is_error = true }
      end
      if #issues == 0 then
        return { llm_output = "No misspellings found", annotation = "clean" }
      end
      return {
        llm_output = format_issues(text, issues, input.max_issues or 100),
        annotation = ("%d issue%s"):format(#issues, #issues == 1 and "" or "s"),
      }
    end,
  })

  maki.api.register_command({
    name = "/spell",
    description = "Spell check text; `/spell add|remove <word>` edits your word list; `/spell on|off` toggles autocorrect",
    nargs = "*",
    handler = function(o)
      local arg = o.args:match("^%s*(.-)%s*$")
      if arg == "on" or arg == "off" then
        opts.autocorrect = arg == "on"
        maki.ui.flash("spellcheck: autocorrect " .. arg)
        return
      end
      local action, word = arg:match("^(%a+)%s+(%S+)$")
      if action == "add" or action == "remove" then
        maki.async.run(function()
          if action == "add" then
            local ok, err = learn_word(word)
            maki.ui.flash(ok and ("spellcheck: added %q"):format(word) or ("spellcheck: " .. tostring(err)))
          else
            local ok, err = forget_word(word)
            if ok == nil then
              maki.ui.flash("spellcheck: " .. tostring(err))
            else
              maki.ui.flash(ok and ("spellcheck: removed %q"):format(word) or ("spellcheck: %q was not in your list"):format(word))
            end
          end
        end)
        return
      end
      if not arg:find("%a") then
        maki.ui.flash("usage: /spell <text> | /spell add|remove <word> | /spell on|off (autocorrect is " .. (opts.autocorrect and "on" or "off") .. ")")
        return
      end
      maki.async.run(function()
        local issues, err = M.check(o.args)
        if not issues then
          maki.notify("spellcheck: " .. err, "error")
          return
        end
        maki.ui.flash(#issues == 0 and "spellcheck: no typos" or short_summary(issues))
      end)
    end,
  })

  maki.api.create_autocmd("InputChanged", {
    callback = function(ev)
      if opts.autocorrect then
        on_input_changed(ev)
      end
    end,
  })
end

local registered = false

function M.setup(user_opts)
  for k, v in pairs(user_opts or {}) do
    opts[k] = v
  end
  if not registered then
    registered = true
    register()
  end
  if opts.check_key then
    maki.keymap.set("n", opts.check_key, check_input, { desc = "Spell check chat input" })
  end
  if opts.fix_key then
    maki.keymap.set("n", opts.fix_key, fix_input, { desc = "Fix typos in chat input" })
  end
end

return M
