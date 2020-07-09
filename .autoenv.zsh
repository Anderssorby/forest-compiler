#!/bin/zsh
run () {
    forest build $1 > o.wat
    ./wasm-interp o.wat --debug
}
