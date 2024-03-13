import simplifile.{read, write}
import shellout.{command}
import gleam/io
import gleam/result
import gleam/regex
import gleam/list
import gleam/string
import gleam/json
import gleam/dynamic.{field, list, string}

pub fn main() {
  case pipeline() {
    Ok(_) -> 0
    Error(e) -> {
      let #(_, error_output) = e
      io.println("\u{001b}[31m" <> error_output <> "\u{001b}[0m")
      1
    }
  }
}

fn pipeline() {
  let docker_tag = "bunlovesnode/bun"
  let assert Ok(current_bun_version) = read_current_bun_version()
  io.println(
    "Current bun version: " <> current_bun_version.current_bun_version <> "\n",
  )
  let bun_docker_version = {
    current_bun_version.current_bun_version
    |> docker_version()
  }
  let assert Ok(dockerfile_template) = read_file("../template.Dockerfile")
  let assert Ok(_) = {
    let dockerfile_content =
      string.replace(
        dockerfile_template,
        "{CURRENT_BUN_VERSION}",
        current_bun_version.current_bun_version,
      )
    let assert Ok(amd_regex) = regex.from_string("#AMD(?:\r?|\n|.)+##AMD")
    let assert Ok(arm_regex) = regex.from_string("#ARM(?:\r?|\n|.)+##ARM")
    let assert [amd_match] =
      regex.scan(with: amd_regex, content: dockerfile_content)
    let assert [arm_match] =
      regex.scan(with: arm_regex, content: dockerfile_content)

    let _ =
      dockerfile_content
      |> string.replace(amd_match.content, "")
      |> write_file("../arm64.Dockerfile")
    let _ =
      dockerfile_content
      |> string.replace(arm_match.content, "")
      |> write_file("../amd64.Dockerfile")
  }
  let assert Ok(nodejs_versions) = read_nodejs_versions()
  nodejs_versions.nodejs_versions
  |> list.map(fn(nodejs_version) {
    let nodejs_docker_version = {
      nodejs_version
      |> docker_version()
    }
    let amd64_url = {
      "https://nodejs.org/dist/v{VERSION}/node-v{VERSION}-linux-x64.tar.xz"
      |> string.replace("{VERSION}", nodejs_version)
    }
    let arm64_url = {
      "https://nodejs.org/dist/v{VERSION}/node-v{VERSION}-linux-arm64.tar.xz"
      |> string.replace("{VERSION}", nodejs_version)
    }
    io.println("Building images")
    let result = {
      [[amd64_url, "amd64"], [arm64_url, "arm64"]]
      |> list.map(fn(url_arch) {
        let assert [url, arch] = url_arch
        let args = [
          "buildx",
          "build",
          ".",
          "--file",
          arch <> ".Dockerfile",
          "--build-arg",
          "NODEJS_URL=" <> url,
          "--platform",
          "linux/" <> arch,
          "--target",
          arch,
          "--tag",
          docker_tag
            <> ":"
            <> current_bun_version.current_bun_version
            <> "-node"
            <> nodejs_docker_version
            <> "-"
            <> arch,
          "--tag",
          docker_tag
            <> ":"
            <> bun_docker_version
            <> "-node"
            <> nodejs_docker_version
            <> "-"
            <> arch,
        ]
        io.println(string.join(["docker", ..args], " "))
        let result = command(run: "docker", in: "..", opt: [], with: args)
        case result {
          Ok(_) -> {
            io.println(
              "\u{001b}[32mSuccessfully built " <> arch <> " image\u{001b}[0m",
            )
          }
          Error(e) -> {
            let #(_, error_output) = e
            io.println(
              "============BEGIN ERROR============\n"
              <> error_output
              <> "\n============END ERROR============\n"
              <> "arch: "
              <> arch,
            )
          }
        }
        let assert Ok(_) = result
        io.println("Pushing image: " <> nodejs_version <> " and arch: " <> arch)
        let result =
          result.all(
            [current_bun_version.current_bun_version, bun_docker_version]
            |> list.map(fn(bun_tag_version) {
              let args = [
                "push",
                docker_tag
                  <> ":"
                  <> bun_tag_version
                  <> "-node"
                  <> nodejs_docker_version
                  <> "-"
                  <> arch,
              ]
              io.println(string.join(["docker", ..args], " "))
              let result = command(run: "docker", in: "..", opt: [], with: args)
              case result {
                Ok(_) -> {
                  io.println("\u{001b}[32mOk\u{001b}[0m")
                }
                Error(e) -> {
                  let #(_, error_output) = e
                  io.println(
                    "============BEGIN ERROR============\n"
                    <> error_output
                    <> "\n============END ERROR============\n"
                    <> "arch: "
                    <> arch,
                  )
                }
              }
              result
            }),
          )
        let assert Ok(_) = result
        Ok(Nil)
      })
    }
    io.println("Creating manifest")
    let result =
      result.all(
        [current_bun_version.current_bun_version, bun_docker_version]
        |> list.map(fn(bun_tag_version) {
          let _ =
            command(run: "docker", in: "..", opt: [], with: [
              "manifest",
              "rm",
              docker_tag
                <> ":"
                <> bun_tag_version
                <> "-node"
                <> nodejs_docker_version,
            ])
          let result =
            command(run: "docker", in: "..", opt: [], with: [
              "manifest",
              "create",
              docker_tag
                <> ":"
                <> bun_tag_version
                <> "-node"
                <> nodejs_docker_version,
              docker_tag
                <> ":"
                <> bun_tag_version
                <> "-node"
                <> nodejs_docker_version
                <> "-amd64",
              docker_tag
                <> ":"
                <> bun_tag_version
                <> "-node"
                <> nodejs_docker_version
                <> "-arm64",
            ])
          result
        }),
      )
    let assert Ok(_) = result
    io.println("Pushing manifest")
    let result =
      result.all(
        [current_bun_version.current_bun_version, bun_docker_version]
        |> list.map(fn(bun_tag_version) {
          command(run: "docker", in: "..", opt: [], with: [
            "manifest",
            "push",
            docker_tag
              <> ":"
              <> bun_tag_version
              <> "-node"
              <> nodejs_docker_version,
          ])
        }),
      )
    let assert Ok(_) = result
    io.println("Removing images")
    let result =
      result.all(
        [current_bun_version.current_bun_version, bun_docker_version]
        |> list.map(fn(bun_tag_version) {
          let _ =
            command(run: "docker", in: "..", opt: [], with: [
              "rmi",
              docker_tag
                <> ":"
                <> bun_tag_version
                <> "-node"
                <> nodejs_docker_version
                <> "-amd64",
              docker_tag
                <> ":"
                <> bun_tag_version
                <> "-node"
                <> nodejs_docker_version
                <> "-arm64",
            ])
          Ok(Nil)
        }),
      )
    let assert Ok(_) = result
    result
  })
  |> result.all()
}


fn docker_version(full_version: String) -> String {
  full_version
  |> string.split(".")
  |> list.take(2)
  |> string.join(".")
}

fn read_current_bun_version() -> Result(CurrentBunVersion, Nil) {
  use file <- result.try(read_file("../current-bun-version.json"))
  use obj <- result.try(parse_current_bun_version_json(file))
  Ok(obj)
}

fn parse_current_bun_version_json(
  json_string: String,
) -> Result(CurrentBunVersion, Nil) {
  let decoder =
    dynamic.decode1(CurrentBunVersion, field("currentBunVersion", of: string))
  case json.decode(json_string, decoder) {
    Ok(obj) -> Ok(obj)
    Error(e) -> {
      io.debug(e)
      Error(Nil)
    }
  }
}

fn read_nodejs_versions() -> Result(NodejsVersions, Nil) {
  use file_content <- result.try(read_file("../nodejs-versions.json"))
  use obj <- result.try(parse_nodejs_versions_json(file_content))
  Ok(obj)
}

fn parse_nodejs_versions_json(
  json_string: String,
) -> Result(NodejsVersions, Nil) {
  let decoder =
    dynamic.decode1(NodejsVersions, field("nodejsVersions", of: list(string)))
  case json.decode(json_string, decoder) {
    Ok(obj) -> Ok(obj)
    Error(e) -> {
      io.debug(e)
      Error(Nil)
    }
  }
}

fn read_file(filename: String) -> Result(String, Nil) {
  case read(filename) {
    Ok(file) -> Ok(file)
    Error(e) -> {
      io.debug(e)
      Error(Nil)
    }
  }
}

fn write_file(file_content: String, filename: String) -> Result(Nil, Nil) {
  case write(filename, file_content) {
    Ok(Nil) -> Ok(Nil)
    Error(e) -> {
      io.debug(e)
      Error(Nil)
    }
  }
}

pub type CurrentBunVersion {
  CurrentBunVersion(current_bun_version: String)
}

pub type NodejsVersions {
  NodejsVersions(nodejs_versions: List(String))
}
