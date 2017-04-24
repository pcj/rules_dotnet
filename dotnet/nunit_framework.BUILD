load("@io_bazel_rules_dotnet//dotnet:csharp.bzl", "dll_import")

filegroup(
    name = "net_2_0",
    srcs = glob(["bin/net-2.0/*.dll"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "net_3.5",
    srcs = glob(["bin/net-3.5/*.dll"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "net_4_0",
    srcs = glob(["bin/net-4.0/*.dll"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "net_4_5",
    srcs = glob(["bin/net-4.5/*.dll"]),
    visibility = ["//visibility:public"],
)

dll_import(
  name = "4_5",
  srcs = [
      ":net_4_5",
  ],
  visibility = ["//visibility:public"],
)
