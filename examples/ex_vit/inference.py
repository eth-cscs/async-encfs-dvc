#!/usr/bin/env python3

import os
import argparse
import yaml
import pickle
from types import SimpleNamespace
import torch
import torch.nn as nn
from torch.utils.data import DataLoader
import torchvision
from torchvision.transforms import Compose, ToTensor, Resize
from torch.hub import tqdm

from model import ViT


def eval_fn(config, model, inference_loader, criterion, device):
    model.eval()
    total_loss = 0.0
    tk = tqdm(inference_loader, desc="[INFERENCE]")

    predictions = []

    for t, data in enumerate(tk):
        images, labels = data
        images, labels = images.to(device), labels.to(device)

        logits = model(images)
        probabilities = nn.functional.softmax(logits, dim=-1)
        predictions.append(torch.argmax(probabilities, dim=-1))

        loss = criterion(logits, labels)

        total_loss += loss.item()
        tk.set_postfix({"Loss": "%6f" % float(total_loss / (t + 1))})
        if config.dry_run:
            break
    
    return predictions


def main():
    parser = argparse.ArgumentParser(description='Vision Transformer in PyTorch')

    parser.add_argument('--training-output', type=str,
                        help='Path to trained model')
    parser.add_argument('--inference-input', type=str,
                        help='Path to Vision Transformer inference data')
    parser.add_argument('--config', type=str,
                        help='YAML file with model hyperparameters')
    parser.add_argument('--inference-output', type=str,
                        help='Path to save inference results to')
    
    parser.add_argument('--no-cuda', action='store_true', default=False,
                        help='disables CUDA training')
    parser.add_argument('--dry-run', action='store_true', default=False,
                        help='quickly check a single pass')

    args = parser.parse_args()

    with open(args.config) as f:
        config = yaml.load(f, Loader=yaml.FullLoader)

    config['batch_size'] = config['global_batch_size']  # not performed in parallel
    config.update(vars(args))
    config = SimpleNamespace(**config)

    use_cuda = not config.no_cuda and torch.cuda.is_available()
    device = torch.device("cuda" if use_cuda else "cpu")

    transforms = Compose([
        Resize((config.img_size, config.img_size)),
        ToTensor()
    ])

    # This is specifically for the CIFAR10 test dataset as an inference input for demonstration purposes
    inference_data = torchvision.datasets.CIFAR10(root=config.inference_input, train=False, download=False, transform=transforms)
    inference_loader = DataLoader(inference_data, batch_size=config.batch_size, shuffle=False)

    model = ViT(config).to(device)

    model.load_state_dict(torch.load(
        os.path.join(config.training_output, "best-weights.pt")))

    model = model.to(device)

    criterion = nn.CrossEntropyLoss()  # well-defined as using test set for demonstration

    predictions = eval_fn(config, model, inference_loader, criterion, device)
    if use_cuda:
        predictions = [pred.cpu() for pred in predictions]

    with open(os.path.join(config.inference_output,
                        f"predicted_labels.pkl"), 'wb') as f:
        pickle.dump([p.numpy() for p in predictions], f)


if __name__ == "__main__":
    main()