#!/usr/bin/env python3

import os
import argparse
import torchvision


parser = argparse.ArgumentParser(description='Fetch CIFAR10 dataset.')
parser.add_argument('--in-output', required=True)
args = parser.parse_args()

if os.path.isdir(args.in_output) and not os.listdir(args.in_output):
    raise RuntimeError(f"--in-output parameter {args.in_output} should be an empty directory")

# Downloading dataset
dataset_train = torchvision.datasets.CIFAR10(root=args.in_output, train=True, download=True)
dataset_test = torchvision.datasets.CIFAR10(root=args.in_output, train=False, download=True)
print(f"Finished fetching training and test dataset to {args.in_output}:\n{dataset_train}\n{dataset_test}")
