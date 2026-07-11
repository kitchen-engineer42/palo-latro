-- game/text.lua — the G.TEXT localization seam. All player-facing strings come from here
-- (never string literals in UI code), so a localization file can fill G.TEXT later (:
-- shipped static; no runtime translation service). Themed verbs: a "hand" = a Ship (launch),
-- a "discard" = a Pivot.
G.TEXT.title       = "PALO LATRO"
G.TEXT.ship        = "Ship"
G.TEXT.pivot       = "Pivot"
G.TEXT.target      = "ARR Target"
G.TEXT.arr         = "ARR"
G.TEXT.users       = "Users"
G.TEXT.rev         = "Rev/user"
G.TEXT.ships_left  = "Ships"
G.TEXT.pivots_left = "Pivots"
G.TEXT.win_title   = "IPO!"
G.TEXT.win_sub     = "You hit the bar and raised the round."
G.TEXT.lose_title  = "Startup died"
G.TEXT.lose_sub    = "Out of runway before you hit ARR."
G.TEXT.restart     = "click / press R to start over"
G.TEXT.hint_select = "Select up to 5 tech cards, then Ship to launch a product."

return G.TEXT
