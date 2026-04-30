# Third-Party Notices

This project is licensed under the **PolyForm Noncommercial License 1.0.0** —
see [LICENSE](./LICENSE).

> Required Notice: Copyright 2025 Working Ants Inc. (Panama)

This `Required Notice:` line MUST be propagated by anyone who redistributes
this software, in accordance with the Notices section of the PolyForm
Noncommercial License 1.0.0.

The first-party code in this repository (under `src/`, `test/`, `script/`) is
copyright Working Ants Inc. The repository also bundles or links to the
following third-party software, each provided under its own license; the
upstream notices are reproduced verbatim below to comply with attribution
requirements.

---

## OpenZeppelin Contracts

- Path: `lib/openzeppelin-contracts/`
- Upstream: https://github.com/OpenZeppelin/openzeppelin-contracts
- Vendored license file: `lib/openzeppelin-contracts/LICENSE`
- License: **MIT**

> The MIT License (MIT)
>
> Copyright (c) 2016-2025 Zeppelin Group Ltd
>
> Permission is hereby granted, free of charge, to any person obtaining
> a copy of this software and associated documentation files (the
> "Software"), to deal in the Software without restriction, including
> without limitation the rights to use, copy, modify, merge, publish,
> distribute, sublicense, and/or sell copies of the Software, and to
> permit persons to whom the Software is furnished to do so, subject to
> the following conditions:
>
> The above copyright notice and this permission notice shall be
> included in all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
> EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
> MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
> IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
> CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
> TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
> SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

---

## OpenZeppelin Contracts Upgradeable

- Path: `lib/openzeppelin-contracts-upgradeable/`
- Upstream: https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable
- Vendored license file: `lib/openzeppelin-contracts-upgradeable/LICENSE`
- License: **MIT** (identical terms to OpenZeppelin Contracts above)

> Copyright (c) 2016-2025 Zeppelin Group Ltd

---

## Solady

- Path: `lib/solady/`
- Upstream: https://github.com/Vectorized/solady
- Vendored license file: `lib/solady/LICENSE.txt`
- License: **MIT**

> MIT License
>
> Copyright (c) 2022-2025 Solady.
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all
> copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

---

## Forge Standard Library (forge-std)

- Path: `lib/forge-std/`
- Upstream: https://github.com/foundry-rs/forge-std
- Vendored license files: `lib/forge-std/LICENSE-MIT`, `lib/forge-std/LICENSE-APACHE`
- License: **MIT OR Apache-2.0** (dual-licensed at user's option)

> Copyright Contributors to Forge Standard Library
>
> Licensed under either of:
>   - Apache License, Version 2.0 (`lib/forge-std/LICENSE-APACHE` or
>     http://www.apache.org/licenses/LICENSE-2.0)
>   - MIT license (`lib/forge-std/LICENSE-MIT` or
>     http://opensource.org/licenses/MIT)
>
> at your option.
>
> Unless you explicitly state otherwise, any contribution intentionally
> submitted for inclusion in the work by you, as defined in the Apache-2.0
> license, shall be dual licensed as above, without any additional terms or
> conditions.

---

## Compound Timelock

- Path: `vendor/compound-timelock/`
- Upstream: https://github.com/compound-finance/compound-protocol
- Vendored license file: `vendor/compound-timelock/LICENSE`
- License: **BSD-3-Clause**

> Copyright 2020 Compound Labs, Inc.
>
> Redistribution and use in source and binary forms, with or without
> modification, are permitted provided that the following conditions are met:
>
> 1. Redistributions of source code must retain the above copyright notice,
>    this list of conditions and the following disclaimer.
>
> 2. Redistributions in binary form must reproduce the above copyright notice,
>    this list of conditions and the following disclaimer in the documentation
>    and/or other materials provided with the distribution.
>
> 3. Neither the name of the copyright holder nor the names of its
>    contributors may be used to endorse or promote products derived from this
>    software without specific prior written permission.
>
> THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
> AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
> IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
> ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
> LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
> CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
> SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
> INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
> CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
> ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
> POSSIBILITY OF SUCH DAMAGE.

Note: `vendor/compound-timelock/src/SafeMath.sol` is annotated as derived from
OpenZeppelin Contracts and carries an `// SPDX-License-Identifier: MIT` header
on that basis. The MIT terms reproduced under the OpenZeppelin Contracts
section above apply to that file.
