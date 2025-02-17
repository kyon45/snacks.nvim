local M = {}

local uv = vim.uv or vim.loop

---@class snacks.picker
---@field git_files fun(opts?: snacks.picker.git.files.Config): snacks.Picker
---@field git_log fun(opts?: snacks.picker.git.log.Config): snacks.Picker
---@field git_log_file fun(opts?: snacks.picker.git.log.Config): snacks.Picker
---@field git_log_line fun(opts?: snacks.picker.git.log.Config): snacks.Picker
---@field git_status fun(opts?: snacks.picker.Config): snacks.Picker
---@field git_diff fun(opts?: snacks.picker.Config): snacks.Picker

---@param opts snacks.picker.git.files.Config
---@type snacks.picker.finder
function M.files(opts)
  local args = { "-c", "core.quotepath=false", "ls-files", "--exclude-standard", "--cached" }
  if opts.untracked then
    table.insert(args, "--others")
  elseif opts.submodules then
    table.insert(args, "--recurse-submodules")
  end
  local cwd = vim.fs.normalize(opts and opts.cwd or uv.cwd() or ".") or nil
  return require("snacks.picker.source.proc").proc(vim.tbl_deep_extend("force", {
    cmd = "git",
    args = args,
    ---@param item snacks.picker.finder.Item
    transform = function(item)
      item.cwd = cwd
      item.file = item.text
    end,
  }, opts or {}))
end

---@param opts snacks.picker.git.log.Config
---@type snacks.picker.finder
function M.log(opts, filter)
  local args = {
    "log",
    "--pretty=format:%h %s (%ch)",
    "--abbrev-commit",
    "--decorate",
    "--date=short",
    "--color=never",
    "--no-show-signature",
    "--no-patch",
  }
  if opts.follow and not opts.current_file then
    opts.follow = nil
  end

  local file ---@type string?
  if opts.current_line then
    local cursor = vim.api.nvim_win_get_cursor(filter.current_win)
    file = vim.api.nvim_buf_get_name(filter.current_buf)
    local line = cursor[1]
    args[#args + 1] = "-L"
    args[#args + 1] = line .. ",+1:" .. file
  elseif opts.current_file then
    file = vim.api.nvim_buf_get_name(filter.current_buf)
    if opts.follow then
      args[#args + 1] = "--follow"
    end
    args[#args + 1] = "--"
    args[#args + 1] = file
  end

  local cwd = vim.fs.normalize(file and vim.fn.fnamemodify(file, ":h") or opts and opts.cwd or uv.cwd() or ".") or nil
  return require("snacks.picker.source.proc").proc(vim.tbl_deep_extend("force", {
    cwd = cwd,
    cmd = "git",
    args = args,
    ---@param item snacks.picker.finder.Item
    transform = function(item)
      local commit, msg, date = item.text:match("^(%S+) (.*) %((.*)%)$")
      if not commit then
        error(item.text)
      end
      item.cwd = cwd
      item.commit = commit
      item.msg = msg
      item.date = date
      item.file = file
    end,
  }, opts or {}))
end

---@param opts snacks.picker.Config
---@type snacks.picker.finder
function M.status(opts)
  local args = {
    "--no-pager",
    "status",
    "-uall",
    "--porcelain=v1",
  }

  local cwd = vim.fs.normalize(opts and opts.cwd or uv.cwd() or ".") or nil
  cwd = Snacks.git.get_root(cwd)
  return require("snacks.picker.source.proc").proc(vim.tbl_deep_extend("force", {
    cwd = cwd,
    cmd = "git",
    args = args,
    ---@param item snacks.picker.finder.Item
    transform = function(item)
      local status, file = item.text:sub(1, 2), item.text:sub(4)
      item.cwd = cwd
      item.status = status
      item.file = file
    end,
  }, opts or {}))
end

---@param opts snacks.picker.Config
---@type snacks.picker.finder
function M.diff(opts)
  local args = { "--no-pager", "diff", "--no-color", "--no-ext-diff" }
  local file, line ---@type string?, number?
  local header, hunk = {}, {} ---@type string[], string[]
  local finder = require("snacks.picker.source.proc").proc(vim.tbl_deep_extend("force", {
    cmd = "git",
    args = args,
  }, opts or {}))
  return function(cb)
    local function add()
      if file and line and #hunk > 0 then
        local diff = table.concat(header, "\n") .. "\n" .. table.concat(hunk, "\n")
        cb({
          text = file .. ":" .. line,
          file = file,
          pos = { line, 0 },
          preview = { text = diff, ft = "diff", loc = false },
        })
      end
      hunk = {}
    end
    finder(function(proc_item)
      local text = proc_item.text
      if text:find("diff", 1, true) == 1 then
        add()
        file = text:match("^diff .* a/(.*) b/.*$")
        header = { text }
      elseif file and #header < 4 then
        header[#header + 1] = text
      elseif text:find("@", 1, true) == 1 then
        add()
        -- Hunk header
        -- @example "@@ -157,20 +157,6 @@ some content"
        line = tonumber(string.match(text, "@@ %-.*,.* %+(.*),.* @@"))
        hunk = { text }
      elseif #hunk > 0 then
        hunk[#hunk + 1] = text
      else
        error("unexpected line: " .. text)
      end
    end)
    add()
  end
end

---@param opts snacks.picker.Config
---@type snacks.picker.finder
function M.branches(opts)
  local args = { "--no-pager", "branch", "--no-color", "-vvl" }
  local cwd = vim.fs.normalize(opts and opts.cwd or uv.cwd() or ".") or nil
  cwd = Snacks.git.get_root(cwd)

  local pattern_hash = "[a-zA-Z0-9]+"
  local patterns = {
    -- stylua: ignore start
    --- e.g. "* (HEAD detached at f65a2c8) f65a2c8 chore(build): auto-generate docs"
    "^(.)%s(%(HEAD detached at " .. pattern_hash .. "%))%s+(" .. pattern_hash .. ")%s*(.*)$",
    --- e.g. "  main                       d2b2b7b [origin/main: behind 276] chore(build): auto-generate docs"
    "^(.)%s(%S+)%s+(".. pattern_hash .. ")%s*(.*)$",
    -- stylua: ignore end
  } ---@type string[]

  return require("snacks.picker.source.proc").proc(vim.tbl_deep_extend("force", {
    cwd = cwd,
    cmd = "git",
    args = args,
    ---@param item snacks.picker.finder.Item
    transform = function(item)
      item.cwd = cwd
      for p, pattern in ipairs(patterns) do
        local status, branch, commit, msg = item.text:match(pattern)
        if status then
          local detached = p == 1
          item.current = status == "*"
          item.branch = not detached and branch or nil
          item.commit = commit
          item.msg = msg
          item.detached = detached
          return
        end
      end
      Snacks.notify.warn("failed to parse branch: " .. item.text)
      return false -- skip items we could not parse
    end,
  }, opts or {}))
end

return M
