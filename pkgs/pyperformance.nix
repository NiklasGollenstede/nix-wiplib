dirname: inputs: let lib = inputs.self.lib.__internal__; in {
    fetchFromGitHub,
    python3Packages, python3,
}: let
    # Example usage: ${lib.getExe pkgs.pyperformance} --venv=${pkgs.pyperformance.venv} --python=${pkgs.python3_xyz} run --benchmarks=chaos --loops=123 -o test.json

    venv = python3.withPackages (pip3: [
        pip3.pyperf
    ]);
in python3Packages.buildPythonApplication rec {
    pname = "pyperformance";
    #version = "1.11.0"; # 2024-03-09
    version = "2025-09-05";

    src = fetchFromGitHub {
        owner = "python"; repo = pname; fetchSubmodules = true;
        #tag = version; sha256 = "sha256-LlIu+Xskf6BkZyBH+HYyTqnfeleKSSQChrlKgEyGV/Q=";
        rev = "15eff0d17fdd6361e5647d562c711b0a9b3160eb"; sha256 = "sha256-8MGjMabvOK53uVPjvfdvQgRoCpGzyYzJ9XAIT3ORJfw=";
    };
    patches = [ inputs.self.patches.pyperformance.determinism ]; # add `--venv` and `--loops` args to `run` command

    pyproject = true;
    build-system = [ python3Packages.setuptools ];

    nativeBuildInputs = [ ];
    propagatedBuildInputs = [
        python3Packages.packaging
        python3Packages.psutil
        python3Packages.pyperf
    ];

    passthru = { inherit venv; };
    meta = {
        description = "Python performance benchmark suite";
        homepage = "https://github.com/python/pyperformance";
        license = lib.licenses.mit;
        mainProgram = "pyperformance";
    };
}
