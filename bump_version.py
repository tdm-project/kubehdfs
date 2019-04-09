# Copyright 2019 CRS4
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""\
Bump chart version.
"""

import argparse
import io
import os
import yaml

Loader = getattr(yaml, "CLoader", "Loader")
Dumper = getattr(yaml, "CDumper", "Dumper")

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
REQ_DIR = os.path.join(THIS_DIR, "charts", "hdfs-k8s")
REQ_FN = os.path.join(REQ_DIR, "requirements.yaml")


def csv(arg):
    return {_.strip() for _ in arg.split(",")}


def dump(doc, f):
    yaml.dump(doc, f, Dumper, default_flow_style=False)


def get_charts_to_bump(all_charts, args):
    unknown = (args.include | args.exclude) - all_charts
    if unknown:
        raise RuntimeError(f"unknown chart(s): {','.join(unknown)}")
    return args.include if args.include else all_charts - args.exclude


def confirm(charts, to_bump):
    w = max(len(_) for _ in charts)
    print(f"{'CHART'.ljust(w)} BUMP")
    for c in sorted(charts):
        print(f"{c.ljust(w)} {'Y' if c in to_bump else 'N'}")
    return input("  Is this OK (y/n)? ").lower().startswith("y")


def bump_chart(fn, version):
    with io.open(fn, "rt") as f:
        doc = yaml.load(f, Loader)
    doc["version"] = version
    with io.open(fn, "wt") as f:
        dump(doc, f)


def main(args):
    with io.open(REQ_FN, "rt") as f:
        doc = yaml.load(f, Loader)
    root = doc["dependencies"]
    charts = {_["name"] for _ in root if _["repository"].startswith("file")}
    to_bump = get_charts_to_bump(charts, args)
    if args.force or confirm(charts, to_bump):
        for dep in root:
            if dep["name"] not in to_bump:
                continue
            dep["version"] = args.version
            d = dep["repository"].split(":", 1)[-1].strip("/")
            fn = os.path.join(REQ_DIR, d, "Chart.yaml")
            bump_chart(fn, args.version)
        with io.open(REQ_FN, "wt") as f:
            dump(doc, f)
        bump_chart(os.path.join(REQ_DIR, "Chart.yaml"), args.version)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", metavar="VERSION",
                        help="new version tag")
    parser.add_argument("-f", "--force", action="store_true",
                        help="don't ask for confirmation")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("-i", "--include", metavar="c1,c2,...", type=csv,
                       default=set(), help="include only these charts")
    group.add_argument("-e", "--exclude", metavar="c1,c2,...", type=csv,
                       default=set(), help="include all charts except these")
    main(parser.parse_args())
