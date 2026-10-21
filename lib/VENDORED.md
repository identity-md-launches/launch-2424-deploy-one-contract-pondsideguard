# Vendored dependencies

All dependencies are committed as ordinary files (no git submodules) so the project builds offline.

| Path | Source | Commit |
| --- | --- | --- |
| lib/v4-core | https://github.com/Uniswap/v4-core (src/, three test routers from src/test/, test/utils/CurrencySettler.sol, licenses/) | 46c6834698c48bc4a463a86d8420f4eb1d7f3b75 |
| lib/solmate | https://github.com/transmissions11/solmate (src/auth/Owned.sol only, needed by v4-core ProtocolFees) | 89365b880c4f3c786bdd453d4b8e8fe410344a69 |
| lib/forge-std | https://github.com/foundry-rs/forge-std (src/) | b013eff2ac4fce26f34d789e6f5c49021c5ee817 |

Licences are kept next to each copy (lib/v4-core/licenses, lib/solmate/LICENSE, lib/forge-std/LICENSE-*).
