#!/usr/bin/env python
"""(Distributed) ML training app"""

import sys

training_output_argv_index = sys.argv.index('--training-output')
if training_output_argv_index == -1:
    raise RuntimeError("Commandline option --training-output is required")
training_output = sys.argv[training_output_argv_index + 1]

print(f"Running training ({sys.argv[0]}, output-dir {training_output}) with args\n{sys.argv}\n")
