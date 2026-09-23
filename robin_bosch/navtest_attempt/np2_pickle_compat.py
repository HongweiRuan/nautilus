# Installed as sitecustomize.py in the eval env (run_eval.sh), so every python process, ray workers included, loads it.
# The navtest metric cache under /closed-loop-e2e/drivor-exp/metric_cache was pickled under numpy 2, whose pickles
# reference `numpy._core.*`; Robin's env pins numpy<2, where that package is `numpy.core`. Alias the former to the latter.
import importlib
import importlib.abc
import importlib.metadata
import importlib.util
import sys


class _Numpy2PickleAlias(importlib.abc.MetaPathFinder, importlib.abc.Loader):
    def find_spec(self, name, path=None, target=None):
        if name == "numpy._core" or name.startswith("numpy._core."):
            return importlib.util.spec_from_loader(name, self)
        return None

    def create_module(self, spec):
        return importlib.import_module("numpy.core" + spec.name[len("numpy._core"):])

    def exec_module(self, module):
        pass


try:
    if int(importlib.metadata.version("numpy").split(".")[0]) < 2:
        sys.meta_path.insert(0, _Numpy2PickleAlias())
except importlib.metadata.PackageNotFoundError:
    pass
