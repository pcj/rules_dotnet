workspace(name = "io_bazel_rules_dotnet")

load("//dotnet:csharp.bzl", "csharp_repositories", "nuget_package")
csharp_repositories()

nuget_package(
    name="ndesk_options", # referenced via path @ndesk_options//:dylibs
    package="NDesk.Options",
    version="0.2.1",
    verbosity = "detailed",
)
