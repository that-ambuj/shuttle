# Developing Shuttle

This document demonstrates how to run the code in this repo, and general tips for developing it.
See [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines about commit style, issues, PRs, and more.

## Project Layout

> 🚨 NOTE 🚨: Big rewrites during our Beta stage has made some details below outdated.
> We intend to properly update the diagram(s) and descriptions when the new architecture stabilizes.

The folders in this repository relate to each other as follow:

```mermaid
graph BT
    classDef default fill:#1f1f1f,stroke-width:0,color:white;
    classDef binary fill:#f25100,font-weight:bolder,stroke-width:0,color:white;
    classDef external fill:#343434,font-style:italic,stroke:#f25100,color:white;

    deployer:::binary
    cargo-shuttle:::binary
    common
    codegen
    e2e
    proto
    provisioner:::binary
    service
    gateway:::binary
    auth:::binary
    user([user service]):::external
    gateway --> common
    gateway -.->|starts instances| deployer
    gateway -->|key| auth
    auth -->|jwt| gateway
    deployer --> proto
    deployer -.->|calls| provisioner
    service ---> common
    deployer --> common
    cargo-shuttle --->|"features = ['builder']"| service
    deployer -->|"features = ['builder']"| service
    cargo-shuttle --> common
    service --> codegen
    proto ---> common
    provisioner --> proto
    e2e -.->|starts up| gateway
    e2e -.->|starts up| auth
    e2e -.->|calls| cargo-shuttle
    user -->|"features = ['codegen']"| service
```

### Binaries

- `cargo-shuttle` is the CLI used by users to initialize, deploy and manage their projects and services on Shuttle.
- `gateway` starts and manages instances of `deployer`. It proxies commands from the user sent via the CLI on port 8001 and traffic on port 8000 to the correct instance of `deployer`.
- `auth` is an authentication service that creates and manages users. In addition to that, requests to the `gateway` that contain an api-key or cookie will be proxied to the `auth` service where it will be converted to a JWT for authorization between internal services (like a `deployer` requesting a database from
`provisioner`).
- `deployer` is a service that runs in its own docker container, one per user project. It manages a project's deployments and state.
- `provisioner` is a service used for requesting databases and other resources, using a gRPC API.
- `admin` is a simple CLI used for admin tasks like reviving and stopping projects, as well as requesting
and renewing SSL certificates through the acme client in the `gateway`.

### Libraries

- `common` contains shared models and functions used by the other libraries and binaries.
- `codegen` contains our proc-macro code which gets exposed to user services from `runtime`.
  The redirect through `runtime` is to make it available under the prettier name of `shuttle_runtime::main`.
- `runtime` contains the `alpha` runtime, which embeds a gRPC server and a `Loader` in a service with the `shuttle_runtime::main` macro.
  The gRPC server receives commands from `deployer` like `start` and `stop`.
  The `Loader` sets up a tracing subscriber and provisions resources for the users service.
  The `runtime` crate also contains the `shuttle-next` binary, which is a standalone runtime binary that is started by the `deployer` or the `cargo-shuttle` CLI, responsible for loading and starting `shuttle-next` services.
- `service` is where our special `Service` trait is defined.
  Anything implementing this `Service` can be loaded by the `deployer` and the local runner in `cargo-shuttle`.
  The `service` library also defines the `ResourceBuilder` and `Factory` trais which are used in our codegen to provision resources.
  The `service` library also contains the utilities we use for compiling users crates with `cargo`.
- `proto` contains the gRPC server and client definitions to allow `deployer` to communicate with `provisioner`, and to allow the `deployer` and `cargo-shuttle` cli to communicate with the `alpha` and `shuttle-next` runtimes.
- `resources` contains various implementations of `ResourceBuilder`, which are consumed in the `codegen` to provision resources.
- `services` contains implementations of `Service` for common Rust web frameworks. Anything implementing `Service` can be deployed by shuttle.
- `e2e` just contains tests which starts up the `deployer` in a container and then deploys services to it using `cargo-shuttle`.

Lastly, the `user service` is not a folder in this repository, but is the user service that will be deployed by `deployer`.

## Running Locally

You can use Docker and docker-compose to test Shuttle locally during development. See the [Docker install](https://docs.docker.com/get-docker/)
and [docker-compose install](https://docs.docker.com/compose/install/) instructions if you do not have them installed already.

> Note for Windows: The current [Makefile](https://github.com/shuttle-hq/shuttle/blob/main/Makefile) does not work on Windows systems by itself - if you want to build the local environment on Windows you could use [Windows Subsystem for Linux](https://learn.microsoft.com/en-us/windows/wsl/install). Additional Windows considerations are listed at the bottom of this page.
> Note for Linux: When building on Linux systems, if the error unknown flag: --build-arg is received, install the docker-buildx package using the package management tool for your particular system.

Clone the Shuttle repository (or your fork):

```bash
git clone git@github.com:shuttle-hq/shuttle.git
cd shuttle
```

> Note: We need the git tags for the local development workflow, but they may not be included when you clone the repository.
To make sure you have them, run `git fetch upstream --tags`, where upstream is the name of the Shuttle remote repository.

The [shuttle examples](https://github.com/shuttle-hq/shuttle-examples) are linked to the main repo as a [git submodule](https://git-scm.com/book/en/v2/Git-Tools-Submodules), to initialize it run the following commands:

```bash
git submodule init
git submodule update
```

You should now be ready to setup a local environment to test code changes to core `shuttle` packages as follows:

From the root of the Shuttle repo, build the required images with:

```bash
USE_PANAMAX=disable make images
```

> Note: The stack uses [panamax](https://github.com/panamax-rs/panamax) by default to mirror crates.io content.
> We do this in order to avoid overloading upstream mirrors and hitting rate limits.
> After syncing the cache, expect to see the panamax volume take about 100GiB of space.
> This may not be desirable for local testing. Therefore `USE_PANAMAX=disable make images` is recommended.

The images get built with [cargo-chef](https://github.com/LukeMathWalker/cargo-chef) and therefore support incremental builds (most of the time). So they will be much faster to re-build after an incremental change in your code - should you wish to deploy it locally straight away.

You can now start a local deployment of Shuttle and the required containers with:

```bash
USE_PANAMAX=disable make up
```

> Note: `make up` can also be run with `SHUTTLE_DETACH=disable`, which means docker-compose will not be run with `--detach`. This is often desirable for local testing.
>
> Note: `make up` can also be run with `HONEYCOMB_API_KEY=<api_key>` if you have a honeycomb.io account and want to test the instrumentation of the services. This is mostly used only by the internal team.
>
> Note: Other useful commands can be found within the [Makefile](./Makefile).

The API is now accessible on `localhost:8000` (for app proxies) and `localhost:8001` (for the control plane). When running `cargo run -p cargo-shuttle` (in a debug build), the CLI will point itself to `localhost` for its API calls.

In order to test local changes to the library crates, you may want to add the below to a `.cargo/config.toml` file. (See [Overriding Dependencies](https://doc.rust-lang.org/cargo/reference/overriding-dependencies.html) for more)

```toml
[patch.crates-io]
shuttle-service = { path = "[base]/shuttle/service" }
shuttle-runtime = { path = "[base]/shuttle/runtime" }

shuttle-aws-rds = { path = "[base]/shuttle/resources/aws-rds" }
shuttle-persist = { path = "[base]/shuttle/resources/persist" }
shuttle-shared-db = { path = "[base]/shuttle/resources/shared-db" }
shuttle-secrets = { path = "[base]/shuttle/resources/secrets" }
shuttle-static-folder = { path = "[base]/shuttle/resources/static-folder" }
shuttle-turso = { path = "[base]/shuttle/resources/turso" }

shuttle-axum = { path = "[base]/shuttle/services/shuttle-axum" }
shuttle-actix-web = { path = "[base]/shuttle/services/shuttle-actix-web" }
shuttle-next = { path = "[base]/shuttle/services/shuttle-next" }
shuttle-poem = { path = "[base]/shuttle/services/shuttle-poem" }
shuttle-poise = { path = "[base]/shuttle/services/shuttle-poise" }
shuttle-rocket = { path = "[base]/shuttle/services/shuttle-rocket" }
shuttle-salvo = { path = "[base]/shuttle/services/shuttle-salvo" }
shuttle-serenity = { path = "[base]/shuttle/services/shuttle-serenity" }
shuttle-thruster = { path = "[base]/shuttle/services/shuttle-thruster" }
shuttle-tide = { path = "[base]/shuttle/services/shuttle-tide" }
shuttle-tower = { path = "[base]/shuttle/services/shuttle-tower" }
shuttle-warp = { path = "[base]/shuttle/services/shuttle-warp" }
```

Before we can login to our local instance of Shuttle, we need to create a user.
The following command inserts a user into the `auth` state with admin privileges:

```bash
# the --key needs to be 16 alphanumeric characters
docker compose -f docker-compose.rendered.yml -p shuttle-dev exec auth /usr/local/bin/service --state=/var/lib/shuttle-auth init-admin --name admin --key dh9z58jttoes3qvt
```

> Note: if you have done this already for this container you will get a "UNIQUE constraint failed"
> error, you can ignore this.

Login to Shuttle service in a new terminal window from the root of the Shuttle directory:

```bash
# the --api-key should be the same one you inserted in the auth state
cargo run -p cargo-shuttle -- login --api-key dh9z58jttoes3qvt
```

> Note: The above commands, along with other useful scripts, can be found in [scripts](./scripts).
> The above lines can instead be done with `source scripts/local-admin.sh`.

Finally, before gateway will be able to work with some projects, we need to create a user for it.
The following command inserts a gateway user into the `auth` state with deployer privileges:

```bash
docker compose -f docker-compose.rendered.yml -p shuttle-dev exec auth /usr/local/bin/service --state=/var/lib/shuttle-auth init-deployer --name gateway --key gateway4deployes
```

Create a new project based on one of the examples.
This will prompt your local gateway to start a deployer container.
Then, deploy it.

```bash
cargo run -p cargo-shuttle -- --wd examples/rocket/hello-world project start
cargo run -p cargo-shuttle -- --wd examples/rocket/hello-world deploy
```

Test if the deployment is working:

```bash
# the Host header should match the URI from the deploy output
curl -H "Host: hello-world-rocket-app.unstable.shuttleapp.rs" localhost:8000
#              ^^^^^^^^^^^^^^^^^^^^^^ this will be the project name
```

View logs from the current deployment:

```bash
# append `--follow` to this command for a live feed of logs
cargo run -p cargo-shuttle -- --wd examples/rocket/hello-world logs
```

### Testing deployer only

The steps outlined above starts all the services used by Shuttle locally (ie. both `gateway` and `deployer`). However, sometimes you will want to quickly test changes to `deployer` only. To do this replace `make up` with the following:

```bash
# if you didn't do this already, make the images
USE_PANAMAX=disable make images

# then generate the local docker-compose file
make docker-compose.rendered.yml

# then run
docker compose -f docker-compose.rendered.yml up provisioner resource-recorder
```

This starts the provisioner and the auth service, while preventing `gateway` from starting up.
Make sure an admin user is inserted into auth and that the key is used by cargo-shuttle. See above.

We're now ready to start a local run of the deployer:

```bash
cargo run -p shuttle-deployer -- --provisioner-address http://localhost:3000 --auth-uri http://localhost:8008 --resource-recorder http://localhost:8007 --proxy-fqdn local.rs --admin-secret dh9z58jttoes3qvt --local --project-id "01H7WHDK23XYGSESCBG6XWJ1V0" --project <name>
```

The `<name>` needs to match the name of the project that will be deployed to this deployer.
This is the `Cargo.toml` or `Shuttle.toml` name for the project.

Now that your local deployer is running, you can run commands against it using the cargo-shuttle CLI.
It needs to have the same project name as the one you submitted when starting the deployer above.

```bash
cargo run -p cargo-shuttle -- --wd <path> --name <name> deploy
```

### Using Podman instead of Docker

If you want to use Podman instead of Docker, you can configure the build process with environment variables.

Use Podman for building container images by setting `DOCKER_BUILD`.

```sh
export DOCKER_BUILD=podman build --network host
```

The Shuttle containers expect access to a Docker-compatible API over a socket. Expose a rootless Podman socket either

- [with systemd](https://github.com/containers/podman/tree/main/contrib/systemd), if your system supports it,

    ```sh
    systemctl start --user podman.service
    ```

- or by [running the server directly](https://docs.podman.io/en/latest/markdown/podman-system-service.1.html).

    ```sh
    podman system service --time=0 unix://$XDG_RUNTIME_DIR/podman.sock
    ```

Then set `DOCKER_SOCK` to the *absolute path* of the socket (no protocol prefix).

```sh
export DOCKER_SOCK=$(podman system info -f "{{.Host.RemoteSocket.Path}}")
```

Finally, configure Docker Compose. You can either

- configure Docker Compose to use the Podman socket by setting `DOCKER_HOST` (including the `unix://` protocol prefix),

    ```sh
    export DOCKER_HOST=unix://$(podman system info -f "{{.Host.RemoteSocket.Path}}")
    ```

- or install [Podman Compose](https://github.com/containers/podman-compose) and use it by setting `DOCKER_COMPOSE`.

    ```sh
    export DOCKER_COMPOSE=podman-compose
    ```

If you are using `nftables`, even with `iptables-nft`, it may be necessary to install and configure the [nftables CNI plugins](https://github.com/greenpau/cni-plugins)

## Running Tests

Shuttle has reasonable test coverage - and we are working on improving this
every day. We encourage PRs to come with tests. If you're not sure about
what a test should look like, feel free to [get in touch](https://discord.gg/shuttle).

To run the unit tests for a specific crate, from the root of the repository run:

```bash
# replace <crate-name> with the name of the crate to test, e.g. `shuttle-common`
cargo test -p <crate-name> --all-features --lib -- --nocapture
```

To run the integration tests for a specific crate (if it has any), from the root of the repository run:

```bash
# replace <crate-name> with the name of the crate to test, e.g. `cargo-shuttle`
cargo test -p <crate-name> --all-features --test '*' -- --nocapture
```

To run the end-to-end (e2e) tests, from the root of the repository run:

```bash
make test
```

> Note: Running all the end-to-end tests may take a long time, so it is recommended to run individual tests shipped as part of each crate in the workspace first.

## Windows Considerations

Currently, if you try to use 'make images' on Windows, you may find that the shell files cannot be read by Bash/WSL. This is due to the fact that Windows may have pulled the files in CRLF format rather than LF[^1], which causes problems with Bash as to run the commands, Linux needs the file in LF format.

Thankfully, we can fix this problem by simply using the `git config core.autocrlf` command to change how Git handles line endings. It takes a single argument:

```bash
git config --global core.autocrlf input
```

This should allow you to run `make images` and other Make commands with no issues.

If you need to change it back for whatever reason, you can just change the last argument from 'input' to 'true' like so:

```bash
git config --global core.autocrlf true
```

After you run this command, you should be able to checkout projects that are maintained using CRLF (Windows) again.

[^1]: https://git-scm.com/book/en/v2/Customizing-Git-Git-Configuration#_core_autocrlf
