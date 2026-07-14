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
and 17 evolved forms, 16 markets, bosses, shops, normal/jumbo/mega packs, consumables, eight funding
stakes, economy and payroll systems, profile progression, deterministic seeded runs, and original
card artwork throughout the playable game.

## License

The Lua source code is available under the [MIT License](LICENSE).

Original artwork, graphs, audio, and other creative game assets are licensed under
[CC BY-NC 4.0](ASSETS-LICENSE.md). Third-party assets remain governed by the license notice bundled
with the relevant asset.
