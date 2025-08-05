
# Work In Progress Nix(OS) Library

The idea of this repo / flake is that whenever I have a Nix function, NixOS Module, nixpkgs package/overlay, related bash script, or combination of those that I need in more than one project, I first put it here so that it can be shared between them.

Eventually I may decide to move parts of this repo into their own flake repositories.
As long as they live here, APIs are not necessarily stable.


## Notables

* [**Append-Only ZFS Backups**](./modules/services/zfs/): Multi-level pushing of incremental snapshots to append-only remotes, for non-`destroy`able, encrypted on- and off-site backups.
* [**Dropbear SSH Server**](./modules/services/dropbear.nix.md): A simple service definition for using dropbear as (main system) SSH server, as a much lighter (but also less feature-rich) alternative of OpenSSH, especially for embedded systems.
* [**Hetzner Cloud VPS Config**](./modules/hardware/hetzner-vps.nix.md): "Device" specific configuration and [fully automated deployment](./modules/hardware/hetzner-deploy-vps.sh) for Hetzner's cloud VPS VMs.
* [**VPS Workers**](./lib/vps-worker.nix.md): (Experimental) definitions for on-demand spawnable workers (for CPU workloads like Nix builds) based on the above.
* [**Ephemeral `kexec` Systems**](./modules/hardware/kexec.nix.md): Deploy complete software systems including kernel as easily as VMs, but run them directly on any hardware device without leaving any persistent traces.
* [**`age-of-nix` Secrets Management**](#age-of-nix-secrets): A simpler API to manage `age` secrets for NixOS hosts (than `agenix`).


## Graduates

Former residents of this repository that now live on their own:
* [`nixos-installer`](https://github.com/NiklasGollenstede/nixos-installer/): A fully automated NixOS CLI installer. Declare your hardware setup and install with a single command -- reproducibly.
* [`nix-functions`](https://github.com/NiklasGollenstede/nix-functions/): A collection of Nix language functions. Has abstractions for dealing with flakes and imports in general, many functions that transform values (attrsets, lists, string, scripts), and more.


## Repo Layout

This Nix Flake repository is laid out and exported as described in [this template](https://github.com/NiklasGollenstede/nix-functions/blob/master/example/template/README.md).

[`lib/`](./lib/) defines new library functions which are exported as the `lib` flake output. Other Nix files in this repo use them as `(lib = inputs.self.lib.__internal__).wip`.

[`modules/`](./modules/) contains NixOS configuration modules. Added options' names start with `wip.` (or a custom prefix, see [Namespacing](#namespacing-in-nixos)).
The modules are inactive by default, and are, where possible, designed to be independent from each other and the other things in this repo.
Some though do have dependencies on added or modified packages, or other modules in the same directory.

[`overlays/`](./overlays/) contains nixpkgs overlays overlays modifying existing packages from `nixpkgs`.
[`pkgs/`](./pkgs/) contains new package definitions.

[`patches/`](./patches/) contains patches which are either applied to the flake's inputs in [`flake.nix`](./flake.nix) or to packages in one of the [`overlays/`](./overlays/).

[`example/hosts/`](./example/hosts/) contains some example host definitions, and [`example/secrets/`](./example/secrets/) a suggested structure for secrets (that is used by some of the example hosts).
[`example/`](./example/) further contains this flake's [default config](./example/defaultConfig/) (see [Namespacing](#namespacing-in-nixos)).
Finally, there is a template with suggestions on how to structure your own flake that imports this one in [`example/template/`](./example/template/).


## `age-of-nix` Secrets

The [`wip.services.secrets`](./modules/services/secrets.nix) module is a slim wrapper around the `agenix` module, and [`age-of-nix` / `nix run .#secrets`](./pkgs/scripts/age-of-nix.sh) is an extended reimplementation of the `agenix` tool.
Their main advantage is that they requires no central list assigning secrets, and they have an overall streamlined API.

To use them, merge this into your flakes outputs:
```nix
    (inputs.wiplib.lib.mkSecretsApp {
        inherit inputs; adminPubKeys = { "${builtins.readFile ./...pub}" = ".*"; }; # ...
    })
```
And add something like this to your hosts' definitions:
```nix
{   wip.services.secrets = {
        enable = true; rootKeyEncrypted = "ssh/host/host@${name}";
        include = [ "shadow/.*" ]; # secrets (regex matching path) that this host needs access to
    };
    users.users.root.hashedPasswordFile = config.age.secrets."shadow/${"root"}".path; # use runtime-decrypted secret
```
Then generate the root decryption (and SSH host) key for each host:
```bash
nix run .#secrets -- --genkey-ssh ::ssh/host/host@{host1,host2,...}
```
And generate the actual secrets you want:
```bash
nix run .#secrets -- --genkey-mkpasswd shadow/root # prompts for and then hashes and encrypts a password (mkpasswd)
nix run .#secrets -- --genkey-ssh ssh/service/$remoteUser@$thisHost # generates an SSH key pair, encrypting the private key and keeping the .pub
nix run .#secrets -- --genkey-wg wg/wgX@$thisHost # generates a WireGuard key pair, encrypting the private key and keeping the .pub
nix run .#secrets -- --edit ... # opens an editor to create a new or edit an existing secret
nix run .#secrets -- --rekey ... # re-encrypts each listed secret to be available for (decryption with the keys of) all hosts that »include« them
```


## Namespacing in NixOS

One of the weak points of NixOS is namespacing. NixOS is traditionally based on the `nixpkgs` monorepo.

The `pkgs` package set is intentionally a global namespace, so that different parts of the system by default use the same instance of each respective package (unless there is a specific reason not to).

The caller to the top-level function constructing a NixOS system can provide `lib` as a set of Nix library functions. This library set is provided as global argument to all imported modules. `nixpkgs` has its default `lib` set, which its modules depend on.
If a flake exports `nixosModules` to be used by another flake to construct systems, then those modules either need to restrict themselves to the default `lib` (in the expectation that that is what will be passed) or instruct the caller to attach some additional functions (exported together with the modules) to `lib`. The former leads to code duplication within the modules, the latter is an additional requirement on the caller, and since `lib` is global, naming conflicts in the `lib` required by different modules are quite possible. The same problem applies to the strategy of supplying additional global arguments to the modules.

Since a nix flake exports instantiated Nix language constructs, not source code, it is possible to define the modules in their source code files wrapped in an outer function, which gets called by the exporting flake before exporting. Consequently, it can supply arguments which are under control of the module author, providing a library set tailored to and exposed exclusively to the local modules, thus completely avoiding naming conflicts.

NixOS modules however define their configuration options in a hierarchical, but global, namespace, and some of those options are necessarily meant to be accessed from modules external to the defining flake.
Usually, for any given module, an importing flake would only have the option to either include a module or not. If two modules define options of conflicting names, then they can't be imported at the same time, even if they could otherwise coexist.

The only workaround (that I could come up with) is to have a flake-level option that allows to change the names of the options defined in the modules exported by that flake, for example by changing their first hierarchical label.
Since flakes are purely functional, the only way to provide configuration to a flake as a whole (as opposed to exporting parts of the flake as functions, which would break the convention on flake exports) is via the flakes `inputs`, and those inputs must be flakes themselves.
The inputs have defaults defined by the flake itself, but can be overridden by the importing flake.

A flake using the modules exported by this flake may thus accept the default that all options are defined under the prefix `wip.`, or it may override its `config` input by a flake of the same shape as [`example/defaultConfig/`](./example/defaultConfig/) but with a different `prefix`.
As a local experiment, the result of running this in a `nix repl` is sufficient:
```nix
:b (import <nixpkgs> { }).writeTextDir "flake.nix" ''
    { outputs = { ... }: {
        prefix = "<str>";
    }; }
''
```


## Other Concepts

### `.xx.md` files

Often, the concept expressed by a source code file is at least as important as the concrete implementation of it.
`nix` unfortunately isn't super readable and also does not have documentation tooling support nearly on par with languages like TypeScript.

Embedding the source code "file" within a MarkDown file emphasizes the importance of textual expressions of the motivation and context of each piece of source code, and should thus incentivize writing sufficient documentation.
Having the documentation right next to the code should also help against documentation rot.

Technically, Nix (and most other code files) don't need to have any specific file extension. By embedding the MarkDown header in a block comment, the file can still be a valid source code file, while the MarkDown header ending in a typed code block ensures proper syntax highlighting of the source code in editors or online repos.
