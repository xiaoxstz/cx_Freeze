# pylint: skip-file

import argparse
import json
import os
import re
import subprocess
import sys
import sysconfig
from pathlib import Path
from typing import List, Union

CI_DIR = Path(sys.argv[0]).parent
TOP_DIR = CI_DIR.parent
PLATFORM = sysconfig.get_platform()
IS_MINGW = PLATFORM.startswith("mingw")
IS_LINUX = PLATFORM.startswith("linux")
IS_MACOS = PLATFORM.startswith("macos")
IS_WINDOWS = sys.platform == "win32" and not IS_MINGW
if IS_WINDOWS:
    PLATFORM = sys.platform
IS_FINAL_VERSION = sys.version_info.releaselevel == "final"

RE_PYTHON_VERSION = re.compile(r"\s*\"*\'*(\d+)\.*(\d*)\.*(\d*)\"*\'*")

IS_CONDA = Path(sys.prefix, "conda-meta").is_dir()
CONDA_EXE = os.environ.get("CONDA_EXE", "conda")
PIP_UPGRADE = os.environ.get("PIP_UPGRADE", False)


def is_supported_platform(platform: Union[str, List[str]]) -> bool:
    if isinstance(platform, str):
        platform = platform.split(",")
    if IS_MINGW:
        platform_in_use = "mingw"
    else:
        platform_in_use = sys.platform
    platform_support = {"darwin", "linux", "mingw", "win32"}
    platform_yes = {plat for plat in platform if not plat.startswith("!")}
    if platform_yes:
        platform_support = platform_yes
    platform_not = {plat[1:] for plat in platform if plat.startswith("!")}
    if platform_not:
        platform_support -= platform_not
    return platform_in_use in platform_support


def is_supported_python(python_version: str) -> bool:
    python_version_in_use = sys.version_info[:3]
    numbers = RE_PYTHON_VERSION.split(python_version)
    operator = numbers[0]
    python_version_required = tuple(int(num) for num in numbers[1:] if num)
    return eval(f"{python_version_in_use}{operator}{python_version_required}")


def install_requirements(requires: Union[str, List[str]]) -> List[str]:
    IS_PIPENV = os.path.isfile("Pipfile")

    if isinstance(requires, str):
        requires = requires.split(",")
    if IS_MINGW:
        HOST_GNU_TYPE = sysconfig.get_config_var("HOST_GNU_TYPE").split("-")
        host_type = HOST_GNU_TYPE[0]  # i686,x86_64
        mingw_w64_hosttype = f"mingw-{HOST_GNU_TYPE[1]}-"  # mingw-w64-
        basic_platform = f"mingw_{host_type}"  # mingw_x86_64
        if len(PLATFORM) > len(basic_platform):
            msys_variant = PLATFORM[len(basic_platform) + 1 :]
            mingw_w64_hosttype += msys_variant + "-"  # clang,ucrt
        mingw_w64_hosttype += host_type

    pip_args = [sys.executable, "-m", "pip", "install"]
    pipenv_args = [sys.executable, "-m", "pipenv", "run", "pip", "install"]
    pacman_args = ["pacman", "--noconfirm", "--needed", "-S"]
    pacman_search = ["pacman", "--noconfirm", "-Ss"]
    conda_install = [CONDA_EXE, "install", "--prefix", sys.prefix, "-y"]
    conda_forge = ["--channel", "conda-forge"]

    installed_packages = []
    pip_pkgs = []
    conda_pkgs = []
    for req in requires:
        installed = False
        alias_for_conda = None
        alias_for_mingw = None
        extra_index_url = None
        find_links = None
        no_deps = False
        platform = None
        python_version = None
        only_binary = False
        pre_release = False
        prefer_binary = False
        require = None
        for req_data in req.split(" "):
            if req_data.startswith("--conda="):
                alias_for_conda = req_data.split("=")[1]
            elif req_data.startswith("--mingw="):
                alias_for_mingw = req_data.split("=")[1]
            elif req_data.startswith("--extra-index-url="):
                extra_index_url = req_data.split("=")[1]
            elif req_data.startswith("--find-links="):
                find_links = req_data.split("=")[1]
            elif req_data == "--no-deps":
                no_deps = True
            elif req_data.startswith("--platform="):
                platform = req_data.split("=")[1]
            elif req_data.startswith("--python-version"):
                python_version = req_data[len("--python-version") :]
            elif req_data == "--only-binary":
                only_binary = True
            elif req_data == "--pre":
                pre_release = True
            elif req_data == "--prefer-binary":
                prefer_binary = True
            else:
                require = req_data
        if require is None:
            # raise
            continue
        if platform and not is_supported_platform(platform):
            continue
        if python_version and not is_supported_python(python_version):
            continue
        if IS_CONDA:
            # minimal support for conda
            if alias_for_conda:
                require = alias_for_conda
            if extra_index_url:
                # install from my package repository
                repository = ["--channel", f"{extra_index_url}/conda"]
                process = subprocess.run(
                    conda_install + repository + conda_forge + [require]
                )
                if process.returncode == 0:
                    installed_packages.append(require)
                    installed = True
                    continue
            conda_pkgs.append(require)
            continue
        if IS_MINGW:
            # create a list of possible names of the package, because in
            # MSYS2 some packages are mapped to python-package or
            # lowercased, etc, for instance:
            # Cython is not mapped
            # cx_Logging is python-cx-logging
            # Pillow is python-Pillow
            # and so on.
            # TODO: emulate find_links support
            # TODO: emulate no_deps support only for python packages
            # TODO: use regex
            if alias_for_mingw:
                require = alias_for_mingw
            package = require.split(";")[0].split("!=")[0]
            package = package.split(">")[0].split("<")[0].split("=")[0]
            packages = [f"python-{package}", package]
            if package != package.lower():
                packages.append(f"python-{package.lower()}")
                packages.append(package.lower())
            for package in packages:
                package = f"{mingw_w64_hosttype}-{package}"
                args = pacman_search + [package]
                process = subprocess.run(
                    args, stdout=subprocess.PIPE, encoding="utf-8"
                )
                if process.returncode == 1:
                    continue  # does not exist with this name
                if process.returncode == 0 and "installed" in process.stdout:
                    installed_packages.append(package)
                    installed = True
                    break
                process = subprocess.run(pacman_args + [package])
                if process.returncode == 0:
                    installed_packages.append(package)
                    installed = True
                    break
            if installed:
                continue
        # use pip
        args = []
        if extra_index_url:
            args.extend(["--extra-index-url", extra_index_url])
        if find_links:
            args.extend(["--find-links", find_links])
        if no_deps:
            args.append("--no-deps")
        if only_binary:
            args.extend(["--only-binary", require, "--no-cache"])
        if pre_release:
            args.append("--pre")
        if prefer_binary:
            args.append("--prefer-binary")
        if args:
            if PIP_UPGRADE:
                args.append("--upgrade")
            args.append(require)
            if IS_PIPENV:
                args = pipenv_args + args
            else:
                args = pip_args + args
            process = subprocess.run(args)
            if process.returncode == 0:
                installed_packages.append(require)
                installed = True
            else:
                if not IS_FINAL_VERSION:
                    # in python preview, try a pre relase of the package too
                    args.append("--pre")
                    process = subprocess.run(args)
                    if process.returncode == 0:
                        installed_packages.append(require)
                        installed = True
                # if not installed:
                #    sys.exit(process.returncode)
        else:
            pip_pkgs.append(require)
    if pip_pkgs:
        if IS_PIPENV:
            args = [sys.executable, "-m", "pipenv", "install"] + pip_pkgs
        else:
            args = pip_args + pip_pkgs
        if PIP_UPGRADE:
            args.append("--upgrade")
        process = subprocess.run(args)
        if process.returncode == 0:
            installed_packages.extend(pip_pkgs)
    if conda_pkgs:
        process = subprocess.run(conda_install + conda_forge + conda_pkgs)
        if process.returncode == 0:
            installed_packages.extend(conda_pkgs)
        # TODO: fallback to pip on error
    return installed_packages


def cx_freeze_version() -> str:
    workdir = os.getcwd()
    os.chdir(Path(workdir).parent)
    try:
        cx_freeze = __import__("cx_Freeze")
    except (ModuleNotFoundError, AttributeError):
        return ""
    finally:
        os.chdir(workdir)
    return cx_freeze.__version__


# process requirements
def install_requires(test_data: list):
    IS_PIPENV = os.path.isfile("Pipfile")
    has_cx_freeze = bool(cx_freeze_version())

    if IS_PIPENV or IS_CONDA or IS_MINGW:
        basic_requirements = []
    else:
        basic_requirements = ["pip"]

    link1 = "https://marcelotduarte.github.io/packages"
    basic_requirements += [
        "setuptools<60 --platform=win32,mingw",
        "setuptools<61 --platform=darwin,linux",
        f"cx_Logging>=3.0 --platform=win32,mingw --extra-index-url={link1}",
        "importlib-metadata>=4.8.3 --python-version<3.10",
        "lief>=0.11.5 --platform=win32,mingw --conda=py-lief",
        "patchelf>=0.12 --platform=linux",
    ]
    installed_packages = install_requirements(basic_requirements)

    if not has_cx_freeze:
        require = "cx_Freeze"
        installed_packages += install_requirements(
            f"{require} --pre --only-binary --extra-index-url={link1}"
        )
        if require not in installed_packages:
            sys.exit(255)  # to disable this code for now
            if IS_CONDA:
                platform_opt = "--platform=darwin,linux"
                conda_requirements = [
                    f"c-compiler {platform_opt}",
                    f"libpython-static --python-version>=3.8 {platform_opt}",
                ]
                installed_packages += install_requirements(conda_requirements)
                build_cmd = [sys.executable, "-m", "pip", "install"]
                build_args = [".", "--no-deps", "--no-cache-dir", "-vvv"]
                process = subprocess.run(build_cmd + build_args, cwd=TOP_DIR)
                # TODO: check if installed
            else:
                installed_packages += install_requirements("build")
                build_cmd = [sys.executable, "-m", "build"]
                build_args = ["-o", TOP_DIR / "wheelhouse"]
                process = subprocess.run(build_cmd + build_args, cwd=TOP_DIR)
            if process.returncode == 0:
                installed_packages += install_requirements(require)

    requires = test_data.get("requirements", [])
    if requires:
        installed_packages += install_requirements(requires)
    if installed_packages:
        print("Requirements installed:", " ".join(installed_packages))


def get_app(name: str, test_data: list, number: int):
    test_app = test_data.get("test_app", [f"test_{name}"])
    if isinstance(test_app, str):
        test_app = [test_app]
    line = int(number or 0)
    # for app in test_app[:]:
    #    if IS_MINGW and app.startswith("gui:"):
    #        test_app.remove(app)
    if line < len(test_app):
        print(test_app[line])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory")
    parser.add_argument("--get-app", type=int)
    parser.add_argument("--install-requires", action="store_true")
    args = parser.parse_args()
    path = Path(args.directory)
    test_sample = path.name

    # verify if platform to run is in use
    test_json = CI_DIR / "build-test.json"
    test_data = json.loads(test_json.read_text()).get(test_sample, {})
    platform = test_data.get("platform", [])
    if platform and not is_supported_platform(platform):
        sys.exit()

    if args.install_requires:
        workdir = os.getcwd()
        # work in samples directory
        os.chdir(path)
        install_requires(test_data)
        os.chdir(workdir)
    elif args.get_app >= 0:
        get_app(test_sample, test_data, args.get_app)
    else:
        parser.error("invalid parameters.")


if __name__ == "__main__":
    main()
