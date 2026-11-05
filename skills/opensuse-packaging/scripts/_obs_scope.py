"""Which repo/arch of an OBS build counts, shared by gate.sh --obs-build and
obs-wait.py so the gate and the wait cannot drift: Tumbleweed/Factory and
Leap 16 on x86_64 and aarch64 unless widened, and how the package's link
origin builds each of them. Imported, not run."""

import re

FACTORY_REPO = re.compile(r"openSUSE_(Factory(_\w+)?|Tumbleweed)")
LEAP16_REPO = re.compile(r"(openSUSE_Leap_)?16\.\d+")
ARCHES = {"x86_64", "aarch64"}
# osc results codes the origin uses for a repo/arch it does not build
OFF = {"disabled", "excluded"}


def factory(prj, repo):
    """Whether repo of project prj is a Tumbleweed/Factory repository."""
    return bool(FACTORY_REPO.fullmatch(repo)) or (
        repo == "standard"
        and (prj == "openSUSE:Factory" or prj.startswith("openSUSE:Factory:"))
    )


def judged(prj, repo, arch, leap=True, repos=None, arches=None):
    """Whether repo/arch of a build in prj counts: a Tumbleweed or (with leap)
    Leap 16 repo, or one the compiled regex repos matches, on x86_64,
    aarch64 or an arch the compiled regex arches matches."""
    wanted = (
        factory(prj, repo)
        or (leap and LEAP16_REPO.fullmatch(repo))
        or (repos and repos.search(repo))
    )
    return bool(wanted) and (arch in ARCHES or bool(arches and arches.search(arch)))


def origin(listing, pkg):
    """(project, package) the expanded source listing of pkg links to, else
    None."""
    li = listing.find("linkinfo") if listing is not None else None
    if li is None or not li.get("project"):
        return None
    return li.get("project"), li.get("package") or pkg


def codes(results, pkg):
    """{(repo, arch, flavor suffix): code} of pkg and its multibuild flavors
    in a parsed osc results --xml answer."""
    out = {}
    for r in results.findall("result"):
        for s in r.findall("status"):
            name = s.get("package") or ""
            if name == pkg or name.startswith(pkg + ":"):
                key = (r.get("repository"), r.get("arch"), name[len(pkg) :])
                out[key] = s.get("code") or ""
    return out
