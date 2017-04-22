load("//dotnet:csharp.bzl", "csharp_nunit_test")

csharp_nunit_test(
    name = "MyTest",
    size = "small",
    srcs = [
        "MyTest.cs",
    ],
    deps = [
        "//examples/example_lib:MyClass",
    ],
)
