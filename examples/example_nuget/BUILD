load("//dotnet:csharp.bzl", "csharp_binary")

csharp_binary(
    name = "hello",
    srcs = [
        "Program.cs",
    ],
    deps = [
        "//examples/example_lib:MyClass",
        "@ndesk_options//:dylibs",
    ],
)
