# Palo Latro

Palo Latro is a handcrafted roguelike deck-builder about building an AI startup from an idea to an IPO.
Your deck is a tech stack, hands are app architectures, founders fill the joker role, and each shipped
product scores ARR as `Users × Revenue per User`.

The game is a clean-room LÖVE2D implementation inspired by Balatro. It does not contain Balatro source
code and is not affiliated with or endorsed by LocalThunk, Playstack, or the Balatro team.

## Play

Install [LÖVE 11.x](https://love2d.org), clone this repository, and run:

```sh
love .
```

On macOS, this alternative starts a separate LÖVE instance:

```sh
open -n -a /Applications/love.app --args "$(pwd)"
```

Palo Latro includes the complete blind loop, persistent deckbuilding, twelve app types, 262 founders
and 17 evolved forms, 16 markets, 22 Tech Laws, bosses, shops, normal/jumbo/mega packs, consumables,
eight funding stakes, visible blind-skip Leads, economy and payroll systems, profile progression,
deterministic seeded runs, and original artwork across Founders, Tech, packs, and the initial Tech Law wave.

## Deterministic gameplay protocol

[`game/mimic.lua`](game/mimic.lua) exposes a versioned headless interface for simulations and
accessibility clients: `start`, `observe`, `legal_actions`, and `apply`. Observations contain only
player-visible state, actions may carry an expected step and digest to reject stale decisions, and
all rules, RNG, state transitions, and scoring remain owned by the normal game runtime.

## License

The Lua source code is available under the [MIT License](LICENSE).

Original artwork, graphs, audio, and other creative game assets are licensed under
[CC BY-NC 4.0](ASSETS-LICENSE.md). Third-party assets remain governed by the license notice bundled
with the relevant asset.
