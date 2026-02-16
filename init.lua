-- lua/dirdiff/init.lua
-- for pr to main
local M = {}
local H = {}

-- =============================================================================
-- 1. CONFIGURATION
-- =============================================================================

local config = {
  tree_height = 18,
  icons = {
    same = "[ ] ",
    diff = "[!] ",
    left = "[A] ",
    right = "[B] ",
    dir = " ",
    file = " ",
  },
  hl = {
    help = "SpecialComment",
    same = "Comment",
    diff = "WarningMsg",
    left = "DiffDelete",
    right = "DiffAdd",
    dir = "Directory",
  },
}

local help_lines = {
  " [DirDiff Keymaps]",
  " <CR> / o : Open Diff",
  " q        : Quit",
  " u        : Refresh",
  " s        : Sync (Copy/Delete)",
  " ]c / [c  : Next/Prev Change",
  string.rep("─", 50),
}
local header_offset = #help_lines

local state = {
  tab_page = nil,
  buf_tree = nil,
  win_tree = nil,
  win_a = nil,
  win_b = nil,
  nodes = {},
  root_a = "",
  root_b = "",
}

-- =============================================================================
-- 2. SCANNING ENGINE (With Filtering)
-- =============================================================================

function H.scan_dir(path_a, path_b, depth)
  local entries = {}
  local function get_files(path)
    local map = {}
    if path and vim.fn.isdirectory(path) == 1 then
      for name, type in vim.fs.dir(path) do
        map[name] = type
      end
    end
    return map
  end

  local files_a = get_files(path_a)
  local files_b = get_files(path_b)

  local all_keys = {}
  for k in pairs(files_a) do
    all_keys[k] = true
  end
  for k in pairs(files_b) do
    all_keys[k] = true
  end
  local sorted_keys = vim.tbl_keys(all_keys)
  table.sort(sorted_keys)

  for _, name in ipairs(sorted_keys) do
    local type_a = files_a[name]
    local type_b = files_b[name]
    local full_a = path_a and (path_a .. "/" .. name) or nil
    local full_b = path_b and (path_b .. "/" .. name) or nil

    local node = {
      name = name,
      path_a = full_a,
      path_b = full_b,
      depth = depth,
      status = "same",
      type = (type_a or type_b),
    }

    if not type_b then
      node.status = "left"
    elseif not type_a then
      node.status = "right"
    elseif type_a ~= type_b then
      node.status = "diff"
    elseif type_a == "file" then
      if not H.files_equal(full_a, full_b) then
        node.status = "diff"
      end
    end

    local show_node = false
    local children = {}

    if node.type == "directory" then
      children =
        H.scan_dir((type_a == "directory") and full_a or nil, (type_b == "directory") and full_b or nil, depth + 1)
      if #children > 0 or node.status ~= "same" then
        show_node = true
      end
    else
      if node.status ~= "same" then
        show_node = true
      end
    end

    if show_node then
      table.insert(entries, node)
      for _, child in ipairs(children) do
        table.insert(entries, child)
      end
    end
  end
  return entries
end

function H.files_equal(f1, f2)
  local s1 = vim.uv.fs_stat(f1)
  local s2 = vim.uv.fs_stat(f2)
  if not s1 or not s2 then
    return false
  end
  if s1.size ~= s2.size then
    return false
  end

  local fd1, fd2 = io.open(f1, "rb"), io.open(f2, "rb")
  if not fd1 or not fd2 then
    return false
  end

  local chunk = 4096
  while true do
    local d1, d2 = fd1:read(chunk), fd2:read(chunk)
    if d1 ~= d2 then
      fd1:close()
      fd2:close()
      return false
    end
    if not d1 then
      break
    end
  end
  fd1:close()
  fd2:close()
  return true
end

-- =============================================================================
-- 3. SYNC LOGIC
-- =============================================================================

function H.copy_item(src, dest)
  local is_windows = vim.fn.has("win32") == 1
  if vim.fn.isdirectory(src) == 1 then
    if is_windows then
      vim.fn.system(string.format('xcopy "%s" "%s" /E /I /Y /Q', src, dest))
    else
      vim.fn.system(string.format('cp -r "%s" "%s"', src, dest))
    end
  else
    local content = vim.secure.read(src)
    if content then
      local f = io.open(dest, "w")
      if f then
        f:write(content)
        f:close()
      end
    end
  end
end

function H.delete_item(path)
  local is_windows = vim.fn.has("win32") == 1
  if vim.fn.isdirectory(path) == 1 then
    if is_windows then
      vim.fn.system(string.format('rmdir /S /Q "%s"', path))
    else
      vim.fn.system(string.format('rm -rf "%s"', path))
    end
  else
    vim.fn.delete(path)
  end
end

function M.sync_item()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local idx = cursor[1] - header_offset
  if idx <= 0 then
    return
  end
  local node = state.nodes[idx]
  if not node then
    return
  end

  local msg = string.format("Sync '%s'? [a] (A->B) | [b] (B->A) | [q] Quit: ", node.name)
  local choice = vim.fn.input(msg)
  vim.cmd("redraw")

  local parent_a = node.path_a and vim.fn.fnamemodify(node.path_a, ":h") or state.root_a
  local parent_b = node.path_b and vim.fn.fnamemodify(node.path_b, ":h") or state.root_b
  local path_a = node.path_a or (parent_a .. "/" .. node.name)
  local path_b = node.path_b or (parent_b .. "/" .. node.name)

  if choice == "a" or choice == "A" then
    if node.status == "left" then
      H.copy_item(path_a, path_b)
    elseif node.status == "right" then
      H.delete_item(path_b)
    else
      H.copy_item(path_a, path_b)
    end
    vim.notify("Synced A -> B", vim.log.levels.INFO)
  elseif choice == "b" or choice == "B" then
    if node.status == "right" then
      H.copy_item(path_b, path_a)
    elseif node.status == "left" then
      H.delete_item(path_a)
    else
      H.copy_item(path_b, path_a)
    end
    vim.notify("Synced B -> A", vim.log.levels.INFO)
  elseif choice == "q" or choice == "Q" then
    vim.notify("Cancelled", vim.log.levels.WARN)
    return
  end
  M.refresh()
end

-- =============================================================================
-- 4. UI RENDERING
-- =============================================================================

function M.open(dir_a, dir_b)
  state.root_a = vim.fn.expand(dir_a)
  state.root_b = vim.fn.expand(dir_b)
  if vim.fn.isdirectory(state.root_a) == 0 or vim.fn.isdirectory(state.root_b) == 0 then
    vim.notify("DirDiff: Invalid directories", vim.log.levels.ERROR)
    return
  end
  vim.notify("DirDiff: Scanning...", vim.log.levels.INFO)

  vim.cmd("tabnew")
  state.tab_page = vim.api.nvim_get_current_tabpage()

  vim.cmd("topleft split")
  vim.cmd("resize " .. config.tree_height)
  state.win_tree = vim.api.nvim_get_current_win()
  state.buf_tree = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(state.win_tree, state.buf_tree)

  vim.cmd("wincmd j")
  state.win_a = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  state.win_b = vim.api.nvim_get_current_win()

  M.refresh()
  H.set_buffer_settings()
  H.set_tree_keymaps()
  vim.api.nvim_set_current_win(state.win_tree)
end

function M.refresh()
  state.nodes = H.scan_dir(state.root_a, state.root_b, 0)
  H.render_tree()
end

function H.render_tree()
  local lines = {}
  local highlights = {}

  for i, line in ipairs(help_lines) do
    table.insert(lines, line)
    table.insert(highlights, { i - 1, 0, -1, config.hl.help })
  end

  if #state.nodes == 0 then
    table.insert(lines, "  (Directories are identical)")
  else
    for i, node in ipairs(state.nodes) do
      local indent = string.rep("  ", node.depth)
      local icon_stat = config.icons[node.status]
      local icon_type = node.type == "directory" and config.icons.dir or config.icons.file
      local row_idx = header_offset + i - 1

      table.insert(lines, indent .. icon_stat .. icon_type .. " " .. node.name)

      local hl = config.hl[node.status]
      if node.type == "directory" then
        hl = config.hl.dir
      end
      table.insert(highlights, { row_idx, #indent, #indent + #icon_stat + #icon_type + 1 + #node.name, hl })
    end
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = state.buf_tree })
  vim.api.nvim_buf_set_lines(state.buf_tree, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = state.buf_tree })

  local ns = vim.api.nvim_create_namespace("dirdiff_ns")
  vim.api.nvim_buf_clear_namespace(state.buf_tree, ns, 0, -1)
  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(state.buf_tree, ns, h[4], h[1], h[2], h[3])
  end
end

-- =============================================================================
-- 5. KEYMAPS & LOGIC
-- =============================================================================

function H.set_buffer_settings()
  vim.api.nvim_set_option_value("filetype", "dirdiff", { buf = state.buf_tree })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = state.buf_tree })
  vim.api.nvim_set_option_value("cursorline", true, { win = state.win_tree })
end

function H.set_tree_keymaps()
  local opts = { noremap = true, silent = true, buffer = state.buf_tree }
  vim.keymap.set("n", "<CR>", M.on_select, opts)
  vim.keymap.set("n", "o", M.on_select, opts)
  vim.keymap.set("n", "q", M.close, opts)
  vim.keymap.set("n", "u", function()
    M.refresh()
  end, opts)
  vim.keymap.set("n", "s", M.sync_item, opts)
  vim.keymap.set("n", "]c", function()
    M.jump_diff(1)
  end, opts)
  vim.keymap.set("n", "[c", function()
    M.jump_diff(-1)
  end, opts)
  vim.keymap.set("n", "]h", function()
    M.jump_diff(1)
  end, opts)
  vim.keymap.set("n", "[h", function()
    M.jump_diff(-1)
  end, opts)
end

function M.jump_diff(direction)
  local cursor = vim.api.nvim_win_get_cursor(state.win_tree)
  local current_idx = cursor[1] - header_offset
  if current_idx < 1 then
    current_idx = 0
  end
  local count = #state.nodes
  local i = current_idx + direction
  while i > 0 and i <= count do
    vim.api.nvim_win_set_cursor(state.win_tree, { i + header_offset, 0 })
    return
  end
end

function H.set_diff_keymaps(bufnr)
  local opts = { noremap = true, silent = true, buffer = bufnr }
  vim.keymap.set("n", "q", M.close, opts)
  vim.keymap.set("n", "<leader>u", M.refresh, opts)

  -- ✅ FIX: Force Native Vim Diff Jumps (bypass Gitsigns/LSP overrides)
  vim.keymap.set("n", "]c", function()
    vim.cmd("normal! ]c")
  end, opts)
  vim.keymap.set("n", "[c", function()
    vim.cmd("normal! [c")
  end, opts)

  -- Alias ]h and [h to the same native behavior
  vim.keymap.set("n", "]h", function()
    vim.cmd("normal! ]c")
  end, opts)
  vim.keymap.set("n", "[h", function()
    vim.cmd("normal! [c")
  end, opts)
end

function M.close()
  if not vim.api.nvim_tabpage_is_valid(state.tab_page) then
    return
  end
  local choice = vim.fn.confirm("Are you sure to DirQuit?", "&Yes\n&No", 2)
  if choice == 1 then
    vim.api.nvim_set_current_tabpage(state.tab_page)
    vim.cmd("tabclose")
    state.tab_page = nil
  end
end

function M.update_node_status(path)
  for _, node in ipairs(state.nodes) do
    if node.path_a == path or node.path_b == path then
      if node.type == "file" and node.path_a and node.path_b then
        if H.files_equal(node.path_a, node.path_b) then
          node.status = "same"
        else
          node.status = "diff"
        end
        if node.status == "same" then
          M.refresh()
        else
          H.render_tree()
        end
      end
      break
    end
  end
end

function M.on_select()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local idx = cursor[1] - header_offset
  if idx <= 0 then
    return
  end
  local node = state.nodes[idx]
  if not node or node.type == "directory" then
    return
  end

  vim.api.nvim_set_current_win(state.win_a)
  if node.path_a then
    vim.cmd("edit " .. vim.fn.fnameescape(node.path_a))
    H.set_diff_keymaps(0)
    vim.cmd("diffthis")
    vim.opt_local.foldmethod = "diff"
    vim.opt_local.foldenable = true
    vim.api.nvim_create_autocmd("BufWritePost", {
      buffer = 0,
      callback = function()
        M.update_node_status(node.path_a)
      end,
    })
  else
    vim.cmd("enew")
    vim.cmd("diffthis")
  end
  vim.api.nvim_set_option_value("winbar", "%#DiffDelete# [A] %#Normal# %f", { win = state.win_a })

  vim.api.nvim_set_current_win(state.win_b)
  if node.path_b then
    vim.cmd("edit " .. vim.fn.fnameescape(node.path_b))
    H.set_diff_keymaps(0)
    vim.cmd("diffthis")
    vim.opt_local.foldmethod = "diff"
    vim.opt_local.foldenable = true
    vim.api.nvim_create_autocmd("BufWritePost", {
      buffer = 0,
      callback = function()
        M.update_node_status(node.path_a)
      end,
    })
  else
    vim.cmd("enew")
    vim.cmd("diffthis")
  end
  vim.api.nvim_set_option_value("winbar", "%#DiffAdd# [B] %#Normal# %f", { win = state.win_b })

  vim.api.nvim_set_current_win(state.win_b)
end

vim.api.nvim_create_user_command("DirDiff", function(opts)
  if #opts.fargs ~= 2 then
    vim.notify("Usage: DirDiff <dir_a> <dir_b>", vim.log.levels.ERROR)
    return
  end
  M.open(opts.fargs[1], opts.fargs[2])
end, { nargs = "+", complete = "dir" })

vim.api.nvim_create_user_command("DirDiffQuit", function()
  M.close()
end, {})

return M
