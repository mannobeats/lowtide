# Third-party notices

Lowtide is licensed under the [GPL-3.0](LICENSE). It includes or builds on the following work,
each under its own license, all compatible with the GPL-3.0.

## Code

| Component | Used for | License |
|---|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | The terminal | MIT |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Dictation on the Neural Engine (helper) | Apache-2.0 |
| [mlx-swift](https://github.com/ml-explore/mlx-swift), [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) | Dictation on the GPU (helper) | MIT |
| [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) | Speech-to-text models on MLX (helper) | MIT |
| [PhononCoreML](https://github.com/fermionresearch/phonon-coreml) 1.1.2 | Dictation on the Neural Engine (helper), vendored in `Helpers/Voice/Phonon` with its own [LICENSE](Helpers/Voice/Phonon/LICENSE) and [NOTICE](Helpers/Voice/Phonon/NOTICE) | Apache-2.0 |
| [swift-transformers](https://github.com/huggingface/swift-transformers), [swift-huggingface](https://github.com/huggingface/swift-huggingface), [swift-jinja](https://github.com/huggingface/swift-jinja) | Model downloads and tokenizers (helper) | Apache-2.0 |
| Apple's [swift-collections](https://github.com/apple/swift-collections), [swift-numerics](https://github.com/apple/swift-numerics), [swift-crypto](https://github.com/apple/swift-crypto), [swift-asn1](https://github.com/apple/swift-asn1), [swift-argument-parser](https://github.com/apple/swift-argument-parser), [swift-syntax](https://github.com/swiftlang/swift-syntax) | Support libraries of the packages above | Apache-2.0 |
| [yyjson](https://github.com/ibireme/yyjson) | JSON parsing (helper) | MIT |
| [EventSource](https://github.com/mattt/EventSource) | Support library of swift-huggingface (helper) | MIT |
| [swift-png](https://github.com/tayloraswift/swift-png), [h](https://github.com/rarestype/h) | Support libraries of SwiftTerm | Apache-2.0 |

"(helper)" marks code built only into the dictation helper, `lowtide-voice`.

## Data and artwork

| Component | Used for | License |
|---|---|---|
| [DB-IP Lite](https://db-ip.com/db/lite.php) (`Resources/geo/dbip-*.mmdb`) | Countries and networks of IP addresses | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), "IP Geolocation by DB-IP" |
| [Natural Earth](https://www.naturalearthdata.com) (`Resources/geo/world.json`) | The network map's land and countries | Public domain |
| [Tabler Icons](https://tabler.io/icons) (`Resources/sources`) | Package manager marks | MIT, see [Resources/sources/LICENSE](Resources/sources/LICENSE) |

Dictation models are not part of Lowtide: they're downloaded when you choose them, under
their authors' licenses.
