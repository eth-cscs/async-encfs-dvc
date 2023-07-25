#!/usr/bin/env python3

import os
import argparse
import yaml
from types import SimpleNamespace
import torch
import torch.nn as nn
from torch.utils.data import DataLoader
import torchvision
from torchvision.transforms import Compose, ToTensor, Resize
from torch import optim
import numpy as np
from torch.hub import tqdm

from torch.utils.data.distributed import DistributedSampler
try:
    import horovod.torch as hvd
except ImportError:
    pass

from model import ViT


class TrainEval:

    def __init__(self, args, model, train_dataloader, val_dataloader, optimizer, criterion, device):
        self.model = model
        self.train_dataloader = train_dataloader
        self.val_dataloader = val_dataloader
        self.optimizer = optimizer
        self.criterion = criterion
        self.epoch = args.epochs
        self.device = device
        self.args = args

    def train_fn(self, current_epoch):
        self.model.train()
        total_loss = 0.0
        tk = tqdm(self.train_dataloader, desc="EPOCH" + "[TRAIN]" + str(current_epoch + 1) + "/" + str(self.epoch))

        for t, data in enumerate(tk):
            images, labels = data
            images, labels = images.to(self.device), labels.to(self.device)
            self.optimizer.zero_grad()
            logits = self.model(images)
            loss = self.criterion(logits, labels)
            loss.backward()
            self.optimizer.step()

            if self.args.dist:
                loss = hvd.allreduce(loss, name='train_loss')
            total_loss += loss.item()
            tk.set_postfix({"Loss": "%6f" % float(total_loss / (t + 1))})
            if self.args.dry_run:
                break

        return total_loss / len(self.train_dataloader) / (1 if not self.args.dist else hvd.size())


    def eval_fn(self, current_epoch):
        self.model.eval()
        total_loss = 0.0
        tk = tqdm(self.val_dataloader, desc="EPOCH" + "[VALID]" + str(current_epoch + 1) + "/" + str(self.epoch))

        for t, data in enumerate(tk):
            images, labels = data
            images, labels = images.to(self.device), labels.to(self.device)

            logits = self.model(images)
            loss = self.criterion(logits, labels)

            if self.args.dist:
                loss = hvd.allreduce(loss, name='eval_loss')
            total_loss += loss.item()
            tk.set_postfix({"Loss": "%6f" % float(total_loss / (t + 1))})
            if self.args.dry_run:
                break

        return total_loss / len(self.val_dataloader) / (1 if not self.args.dist else hvd.size())

    def train(self):
        best_valid_loss = np.inf
        best_train_loss = np.inf
        for i in range(self.epoch):
            train_loss = self.train_fn(i)
            val_loss = self.eval_fn(i)

            if val_loss < best_valid_loss:
                if not self.args.dist or hvd.rank() == 0:
                    torch.save(self.model.state_dict(),
                               os.path.join(self.args.training_output, "best-weights.pt"))
                print("Saved Best Weights")
                best_valid_loss = val_loss
                best_train_loss = train_loss
        print(f"Training Loss : {best_train_loss}")
        print(f"Valid Loss : {best_valid_loss}")

    '''
        On default settings:
        
        Training Loss : 2.3081023390197752
        Valid Loss : 2.302861615943909
        
        However, this score is not competitive compared to the 
        high results in the original paper, which were achieved 
        through pre-training on JFT-300M dataset, then fine-tuning 
        it on the target dataset. To improve the model quality 
        without pre-training, we could try training for more epochs, 
        using more Transformer layers, resizing images or changing 
        patch size,
    '''


def main():
    parser = argparse.ArgumentParser(description='Vision Transformer in PyTorch')

    parser.add_argument('--training-input', type=str,
                        help='Path to CIFAR10 training data')
    parser.add_argument('--test-input', type=str,
                        help='Path to CIFAR10 test data')
    parser.add_argument('--config', type=str,
                        help='YAML file with model and training hyperparameters')
    parser.add_argument('--training-output', type=str,
                        help='Path to save trained model to')

    parser.add_argument('--no-cuda', action='store_true', default=False,
                        help='disables CUDA training')
    parser.add_argument('--dry-run', action='store_true', default=False,
                        help='quickly check a single pass')
    parser.add_argument('--dist', action='store_true', default=False,
                        help='enables distributed training')

    args = parser.parse_args()

    with open(args.config) as f:
        config = yaml.load(f, Loader=yaml.FullLoader)

    if args.dist:
        hvd.init()
        if config['global_batch_size'] % hvd.size() != 0:
            raise RuntimeError(f"Batch size ({config['global_batch_size']}) must be a multiple of number of processes ({hvd.size()}).")
        config['batch_size'] = config['global_batch_size']//hvd.size()
    else:
        config['batch_size'] = config['global_batch_size']

    config.update(vars(args))
    config = SimpleNamespace(**config)

    use_cuda = not config.no_cuda and torch.cuda.is_available()
    device = torch.device("cuda" if use_cuda else "cpu")

    transforms = Compose([
        Resize((config.img_size, config.img_size)),
        ToTensor()
    ])
    train_data = torchvision.datasets.CIFAR10(root=config.training_input, train=True, download=False, transform=transforms)
    valid_data = torchvision.datasets.CIFAR10(root=config.test_input, train=False, download=False, transform=transforms)
    if config.dist:
        train_sampler = DistributedSampler(train_data, num_replicas=hvd.size(), rank=hvd.rank())
        valid_sampler = DistributedSampler(valid_data, num_replicas=hvd.size(), rank=hvd.rank())
        train_loader = DataLoader(train_data, batch_size=config.batch_size, sampler=train_sampler)
        valid_loader = DataLoader(valid_data, batch_size=config.batch_size, sampler=valid_sampler)
    else:
        train_loader = DataLoader(train_data, batch_size=config.batch_size, shuffle=True)
        valid_loader = DataLoader(valid_data, batch_size=config.batch_size, shuffle=True)

    model = ViT(config).to(device)

    optimizer = optim.Adam(model.parameters(), lr=config.lr, weight_decay=config.weight_decay)
    if config.dist:
        hvd.broadcast_parameters(model.state_dict(), root_rank=0)
        hvd.broadcast_optimizer_state(optimizer, root_rank=0)
        optimizer = hvd.DistributedOptimizer(optimizer,
                                             named_parameters=model.named_parameters(),
                                             op=hvd.Average)

    criterion = nn.CrossEntropyLoss()

    TrainEval(config, model, train_loader, valid_loader, optimizer, criterion, device).train()


if __name__ == "__main__":
    main()