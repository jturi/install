-- =============================================================================
-- WEZTERM CONFIG (Windows) — installed to %USERPROFILE%\.wezterm.lua
-- =============================================================================
--
-- RELOAD / EDIT THIS FILE
--   Saving the file reloads it automatically.
--   ctrl+shift+r        Reload config by hand
--   After editing in the repo: ./setup.sh --terminal from WSL, or make terminals.
--   List every active binding: wezterm show-keys
--
-- TMUX INTEGRATION
--   Alt is already sent to apps as Meta, so tmux bindings like
--   Alt+l / Alt+j / Alt+1..9 work without any remapping. Prefix is Ctrl+a.
--
-- COMMON WEZTERM DEFAULTS (Windows)
--   ctrl+shift+t        New tab
--   ctrl+shift+w        Close tab
--   ctrl+shift+n        New window
--   ctrl+shift+alt+%    Split right
--   ctrl+shift+alt+"    Split down
--   ctrl+shift+arrows   Move focus between splits
--   ctrl+shift+z        Zoom current split (toggle)
--   ctrl+shift+c / v    Copy / paste
--   ctrl+shift+f        Search scrollback
--   ctrl+shift+k        Clear scrollback
--   ctrl+= / ctrl+-     Increase / decrease font size
--   ctrl+0              Reset font size
--
-- Full default list: https://wezterm.org/config/default-keys.html
-- =============================================================================

local wezterm = require 'wezterm'
local config = wezterm.config_builder()

-- Font size in points
config.font_size = 14.0

return config
