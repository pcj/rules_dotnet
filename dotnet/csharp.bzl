# Copyright 2015 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""CSharp bazel rules"""

_MONO_UNIX_BIN = "/usr/local/bin/mono"

# TODO(jeremy): Windows when it's available.

def _make_csc_flag(flag_start, flag_name, flag_value=None):
  return flag_start + flag_name + (":" + flag_value if flag_value else "")

def _make_csc_deps(deps, extra_files=[]):
  dlls = set()
  refs = set()
  transitive_dlls = set()
  for dep in deps:
    if hasattr(dep, "target_type"):
      dep_type = getattr(dep, "target_type")
      if dep_type == "exe":
        fail("You can't use a binary target as a dependency", "deps")
      if dep_type == "library":
        dlls += [dep.out]
        refs += [dep.name]
      if dep_type == "library_set":
        dlls += dep.out
        refs += [d.basename for d in dep.out]
      if dep.transitive_dlls:
        transitive_dlls += dep.transitive_dlls

  return struct(
      dlls = dlls + set(extra_files),
      refs = refs,
      transitive_dlls = transitive_dlls)

def _get_libdirs(dlls, libdirs=[]):
  return [dep.dirname for dep in dlls] + libdirs

def _make_csc_arglist(ctx, output, depinfo, extra_refs=[]):
  flag_start = ctx.attr._flag_start
  args = [
       # /out:<file>
      _make_csc_flag(flag_start, "out", output.path),
       # /target (exe for binary, library for lib, module for module)
      _make_csc_flag(flag_start, "target", ctx.attr._target_type),
      # /fullpaths
      _make_csc_flag(flag_start, "fullpaths"),
      # /warn
      _make_csc_flag(flag_start, "warn", str(ctx.attr.warn)),
      # /nologo
      _make_csc_flag(flag_start, "nologo"),
  ]

  # /modulename:<string> only used for modules
  libdirs = _get_libdirs(depinfo.dlls)
  libdirs = _get_libdirs(depinfo.transitive_dlls, libdirs)

  # /lib:dir1,[dir1]
  if libdirs:
    args += [_make_csc_flag(flag_start, "lib", ",".join(list(libdirs)))]

  # /reference:filename[,filename2]
  if depinfo.refs or extra_refs:
    args += [_make_csc_flag(flag_start, "reference",
                            ",".join(list(depinfo.refs + extra_refs)))]
  else:
    args += extra_refs

  # /doc
  if hasattr(ctx.outputs, "doc_xml"):
    args += [_make_csc_flag(flag_start, "doc", ctx.outputs.doc_xml.path)]

  # /debug
  debug = ctx.var.get("BINMODE", "") == "-dbg"
  args += [_make_csc_flag(flag_start, "debug")] if debug else []

  # /warnaserror
  # TODO(jeremy): /define:name[;name2]
  # TODO(jeremy): /resource:filename[,identifier[,accesibility-modifier]]

  # /main:class
  if hasattr(ctx.attr, "main_class") and ctx.attr.main_class:
    args += [_make_csc_flag(flag_start, "main", ctx.attr.main_class)]

  # TODO(jwall): /parallel

  return args

_NUNIT_LAUNCHER_SCRIPT = """\
#!/bin/bash

if [[ -e "$0.runfiles" ]]; then
  cd $0.runfiles/{workspace}
fi

# Create top-level symlinks for lib files.
# TODO(jeremy): This is a gross and fragile hack.
# We should be able to do better than this.
for l in {libs}; do
    if [[ ! -e $(basename $l) ]]; then
        # Note: -f required because the symlink may exist
        # even though its current target does not exist.
        ln -s -f $l $(basename $l)
    fi
done

# http://stackoverflow.com/questions/14452550/how-can-i-configure-mono-to-use-the-correct-paths-to-etc-directory-when-the-pre
# https://peteris.rocks/blog/mono-installation-on-ubuntu-server/
export PATH="$PATH:{mono_root}/bin"
export MONO_PATH="{mono_path}:/private/var/tmp/_bazel_pcj/0e7a1a3884ba6d0cdc1ab5a0b0c46b53/external/nunit_framework/bin/net-4.5"
export MONO_CONFIG="{mono_root}/etc/mono/config"
export MONO_CFG_DIR="{mono_root}/etc"
export DYLD_LIBRARY_PATH="{mono_path}:/private/var/tmp/_bazel_pcj/0e7a1a3884ba6d0cdc1ab5a0b0c46b53/external/nunit_framework/bin/net-4.5"
export PKG_CONFIG_PATH="{mono_root}/lib/pkgconfig:{mono_root}/share/pkgconfig"
{mono_exe} {nunit_exe} {libs} "$@"
"""

def _make_nunit_launcher(ctx, depinfo, output):
  libs = ([d.short_path for d in depinfo.dlls] +
          [d.short_path for d in depinfo.transitive_dlls])

  filtered_libs = []
  for lib in libs:
    #if not lib.endswith("nunit.testdata.dll") and not lib.endswith("nunitlite.dll") and not lib.endswith("nunit.framework.dll"):
    if not lib.endswith("slow-nunit-tests.dll") and not lib.endswith("nunit.framework.tests.dll") and not lib.endswith("nunit.testdata.dll") and not lib.endswith("nunitlite.dll") and not lib.endswith("nunit.framework.dll"):
      print("adding test lib %s" % lib)
      filtered_libs.append(lib)

  content = _NUNIT_LAUNCHER_SCRIPT.format(
      mono_exe=ctx.file.mono.short_path,
      mono_path=ctx.attr.mono_toolchain.mono_toolchain.path,
      mono_root=ctx.attr.mono_toolchain.mono_toolchain.root,
      nunit_exe=ctx.files._nunit_exe[0].short_path,
      #libs=" ".join(list(set(filtered_libs))),
      libs=" ".join([output.short_path]),
      workspace=ctx.workspace_name)

  ctx.file_action(output=ctx.outputs.executable, content=content)

_LAUNCHER_SCRIPT = """\
#!/bin/bash

set -e

RUNFILES=$0.runfiles/{workspace}

pushd $RUNFILES

# Create top-level symlinks for .exe and lib files.
# TODO(jeremy): This is a gross and fragile hack.
# We should be able to do better than this.
if [[ ! -e $(basename {exe}) ]]; then
    # Note: -f required because the symlink may exist
    # even though its current target does not exist.
    ln -s -f {exe} $(basename {exe})
fi
for l in {libs}; do
    if [[ ! -e $(basename {workspace}/$l) ]]; then
        ln -s -f $l $(basename {workspace}/$l)
    fi
done

popd

export MONO_PATH="{mono_path}"
export DYLD_LIBRARY_PATH="{mono_path}"

$RUNFILES/{mono_exe} $RUNFILES/$(basename {exe}) "$@"
"""

def _make_launcher(ctx, depinfo, output):
  libs = ([d.short_path for d in depinfo.dlls] +
          [d.short_path for d in depinfo.transitive_dlls])

  # env = {
  #   "MONO_PATH": ctx.attr.mono_toolchain.mono_toolchain.path,
  #   "DYLD_LIBRARY_PATH": ctx.attr.mono_toolchain.mono_toolchain.path,
  # }
  # print("env: %r" % env)

  content = _LAUNCHER_SCRIPT.format(mono_exe=ctx.file.mono.path,
                                    workspace=ctx.workspace_name,
                                    mono_path=ctx.attr.mono_toolchain.mono_toolchain.path,
                                    exe=output.short_path,
                                    libs=" ".join(libs))
  ctx.file_action(output=ctx.outputs.executable, content=content)

def _csc_get_output(ctx):
  output = None
  if hasattr(ctx.outputs, "csc_lib"):
    output = ctx.outputs.csc_lib
  elif hasattr(ctx.outputs, "csc_exe"):
    output = ctx.outputs.csc_exe
  else:
    fail("You must supply one of csc_lib or csc_exe")
  return output

def _csc_collect_inputs(ctx, extra_files=[]):
  depinfo = _make_csc_deps(ctx.attr.deps, extra_files=extra_files)
  inputs = (set(ctx.files.srcs) + depinfo.dlls + depinfo.transitive_dlls
      + [ctx.file.csc])
  srcs = [src.path for src in ctx.files.srcs]
  return struct(depinfo=depinfo,
                inputs=inputs,
                srcs=srcs)

def _csc_compile_action(ctx, assembly, all_outputs, collected_inputs,
                      extra_refs=[]):
  csc_args = _make_csc_arglist(ctx, assembly, collected_inputs.depinfo,
                               extra_refs=extra_refs)
  command_script = " ".join([ctx.file.csc.path] + csc_args +
                            collected_inputs.srcs)

  ctx.action(
      inputs = list(collected_inputs.inputs),
      outputs = all_outputs,
      command = command_script,
      arguments = csc_args,
      progress_message = (
          "Compiling " + ctx.label.package + ":" + ctx.label.name))

def _cs_runfiles(ctx, outputs, depinfo, add_mono=False):
  mono_file = []
  if add_mono:
    mono_file = [ctx.file.mono]
  transitive_files = set(depinfo.dlls + depinfo.transitive_dlls + mono_file) or None
  return ctx.runfiles(
      files = outputs,
      transitive_files = set(depinfo.dlls + depinfo.transitive_dlls + [ctx.file.mono]) or None)

def _csc_compile_impl(ctx):
  if hasattr(ctx.outputs, "csc_lib") and hasattr(ctx.outputs, "csc_exe"):
    fail("exactly one of csc_lib and csc_exe must be defined")

  output = _csc_get_output(ctx)
  outputs = [output] + (
      [ctx.outputs.doc_xml] if hasattr(ctx.outputs, "doc_xml") else [])

  collected = _csc_collect_inputs(ctx)

  depinfo = collected.depinfo
  inputs = collected.inputs
  srcs = collected.srcs

  runfiles = _cs_runfiles(ctx, outputs, depinfo)

  _csc_compile_action(ctx, output, outputs, collected)

  if hasattr(ctx.outputs, "csc_exe"):
    _make_launcher(ctx, depinfo, output)

  return struct(name = ctx.label.name,
                srcs = srcs,
                target_type=ctx.attr._target_type,
                out = output,
                dlls = set([output]),
                transitive_dlls = depinfo.dlls,
                runfiles = runfiles)

def _cs_nunit_run_impl(ctx):
  if hasattr(ctx.outputs, "csc_lib") and hasattr(ctx.outputs, "csc_exe"):
    fail("exactly one of csc_lib and csc_exe must be defined")

  output = _csc_get_output(ctx)
  outputs = [output] + (
      [ctx.outputs.doc_xml] if hasattr(ctx.outputs, "doc_xml") else [])
  outputs = outputs

  collected_inputs = _csc_collect_inputs(ctx, ctx.files._nunit_framework)

  depinfo = collected_inputs.depinfo
  inputs = collected_inputs.inputs
  srcs = collected_inputs.srcs

  runfiles = _cs_runfiles(
      ctx,
      outputs + ctx.files._nunit_exe + ctx.files._nunit_exe_libs,
      depinfo)

  _csc_compile_action(ctx, output, outputs, collected_inputs,
                      extra_refs=["Nunit.Framework"])

  _make_nunit_launcher(ctx, depinfo, output)

  return struct(name=ctx.label.name,
                srcs=srcs,
                target_type=ctx.attr._target_type,
                out=output,
                dlls = (set([output])
                        if hasattr(ctx.outputs, "csc_lib") else None),
                transitive_dlls = depinfo.dlls,
                runfiles=runfiles)

def _find_and_symlink(repository_ctx, binary, env_variable):
  if env_variable in repository_ctx.os.environ:
    return repository_ctx.path(repository_ctx.os.environ[env_variable])
  else:
    found_binary = repository_ctx.which(binary)
    if found_binary == None:
      fail("Cannot find %s. Either correct your path or set the " % binary +
           "%s environment variable." % env_variable)
    repository_ctx.symlink(found_binary, "bin/%s" % binary)
    return binary

def _csharp_autoconf(repository_ctx):
  mono_binary = _find_and_symlink(repository_ctx, "mono", "MONO")
  _find_and_symlink(repository_ctx, "mcs", "CSC")
  path = mono_binary.split('/')
  print("mono binary path: %s" % path)
  toolchain_build = """\
package(default_visibility = ["//visibility:public"])
exports_files(["mono", "mcs"])
load("@io_bazel_rules_dotnet//dotnet:csharp.bzl", "mono_toolchain")
mono_toolchain(
  name = "toolchain",
  root = "{dirname}/Library/Frameworks/Mono.framework/Versions/4.8.1",
  path = "{dirname}/Library/Frameworks/Mono.framework/Versions/4.8.1/lib/mono/4.5",
)
""".format(dirname = "/".join(path[:-2]))
  repository_ctx.file("bin/BUILD", toolchain_build)

_COMMON_ATTRS = {
    # configuration fragment that specifies
    "_flag_start": attr.string(default="-"),
    # code dependencies for this rule.
    # all dependencies must provide an out field.
    "deps": attr.label_list(providers=["out", "target_type"]),
    # source files for this target.
    "srcs": attr.label_list(allow_files = FileType([".cs", ".resx"])),
    # resources to use as dependencies.
    # TODO(jeremy): "resources_deps": attr.label_list(allow_files=True),
    # TODO(jeremy): # name of the module if you are creating a module.
    # TODO(jeremy): "modulename": attri.string(),
    # warn level to use
    "warn": attr.int(default=4),
    # define preprocessor symbols.
    # TODO(jeremy): "define": attr.string_list(),
    # The mono binary and csharp compiler.
    "mono": attr.label(
        default = Label("@mono//bin:mono"),
        allow_files = True,
        single_file = True,
        executable = True,
        cfg = "host",
    ),
    "csc": attr.label(
        default = Label("@mono//bin:mcs"),
        allow_files = True,
        single_file = True,
        executable = True,
        cfg = "host",
    ),
    # The mono_toolchain rule which provides the
    # absolute path to the installed mono
    "mono_toolchain": attr.label(
        providers=["mono_toolchain"],
        default=Label("@mono//bin:toolchain"),
        cfg="host",
    ),
}

_LIB_ATTRS = {
    "_target_type": attr.string(default="library")
}

_NUGET_ATTRS = {
    "srcs": attr.label_list(allow_files = FileType([".dll"])),
    "_target_type": attr.string(default="library_set")
}

_EXE_ATTRS = {
    "_target_type": attr.string(default="exe"),
    # main class to use as entry point.
    "main_class": attr.string(),
}

_NUNIT_ATTRS = {
    "_nunit_exe": attr.label(
      default=Label("@nunit//:nunit_exe"),
      single_file=True,
    ),
    "_nunit_exe_libs": attr.label(
      default=Label("@nunit//:nunit_exe_libs"),
    ),
    "_nunit_framework": attr.label(
      default=Label("@nunit_framework//:net_4_5"),
    ),
}

_LIB_OUTPUTS = {
    "csc_lib": "%{name}.dll",
    "doc_xml": "%{name}.xml",
}

_BIN_OUTPUTS = {
    "csc_exe": "%{name}.exe",
}

csharp_library = rule(
    implementation = _csc_compile_impl,
    attrs = dict(_COMMON_ATTRS.items() + _LIB_ATTRS.items()),
    outputs = _LIB_OUTPUTS,
)
"""Builds a C# .NET library and its corresponding documentation.

Args:
  name: A unique name for this rule.
  srcs: C# `.cs` or `.resx` files.
  deps: Dependencies for this rule
  warn: Compiler warning level for this library. (Defaults to 4).
  csc: Override the default C# compiler.

    **Note:** This attribute may be removed in future versions.
"""

csharp_binary = rule(
    implementation = _csc_compile_impl,
    attrs = dict(_COMMON_ATTRS.items() + _EXE_ATTRS.items()),
    outputs = _BIN_OUTPUTS,
    executable = True,
)
"""Builds a C# .NET binary.

Args:
  name: A unique name for this rule.
  srcs: C# `.cs` or `.resx` files.
  deps: Dependencies for this rule
  main_class: Name of class with `main()` method to use as entry point.
  warn: Compiler warning level for this library. (Defaults to 4).
  csc: Override the default C# compiler.

    **Note:** This attribute may be removed in future versions.
"""

csharp_nunit_test = rule(
    implementation = _cs_nunit_run_impl,
    executable = True,
    attrs = dict(_COMMON_ATTRS.items() + _LIB_ATTRS.items() +
                 _NUNIT_ATTRS.items()),
    outputs = _LIB_OUTPUTS,
    test = True,
)
"""Builds a C# .NET test binary that uses the [NUnit](http://nunit.org) unit
testing framework.

Args:
  name: A unique name for this rule.
  srcs: C# `.cs` or `.resx` files.
  deps: Dependencies for this rule
  warn: Compiler warning level for this library. (Defaults to 4).
  csc: Override the default C# compiler.

    **Note:** This attribute may be removed in future versions.
"""

def _dll_import_impl(ctx):
  inputs = set(ctx.files.srcs)
  return struct(
    name = ctx.label.name,
    target_type = ctx.attr._target_type,
    out = inputs,
    dlls = inputs,
    transitive_dlls = set([]),
  )

dll_import = rule(
  implementation = _dll_import_impl,
  attrs = _NUGET_ATTRS,
)

def _nuget_package_impl(repository_ctx,
                        build_file = None,
                        build_file_content = None):
  # figure out the output_path
  package = repository_ctx.attr.package
  output_dir = repository_ctx.path("")

  mono = repository_ctx.path(repository_ctx.attr.mono_exe)
  nuget = repository_ctx.path(repository_ctx.attr.nuget_exe)

  # assemble our nuget command.
  nuget_cmd = [
    'MONO_LOG_MASK="all"',
    mono,
    "--config", "%s/../etc/mono/config" % mono.dirname,
    nuget,
    "install",
    "-Verbosity", repository_ctx.attr.verbosity,
    "-Version", repository_ctx.attr.version,
    "-OutputDirectory", output_dir,
  ]
  # add the sources from our source list to the command
  for source in repository_ctx.attr.package_sources:
    nuget_cmd += ["-Source", source]

  # Lastly we add the nuget package name.
  nuget_cmd += [repository_ctx.attr.package]
  # execute nuget download.
  result = _execute(repository_ctx, nuget_cmd, print_stdout=True)
  if result.return_code:
    fail("Nuget command failed: %s (%s)" % (result.stderr, " ".join(nuget_cmd)))

  if build_file_content:
    repository_ctx.file("BUILD", build_file_content)
  elif build_file:
    repository_ctx.symlink(repository_ctx.path(build_file), "BUILD")
  else:
    tpl_file = Label("//dotnet:NUGET_BUILD.tpl")
    # add the BUILD file
    repository_ctx.template(
      "BUILD",
      tpl_file,
      {"%{package}": repository_ctx.name,
       "%{output_dir}": "%s" % output_dir})

_nuget_package_attrs = {
  # Sources to download the nuget packages from
  "package_sources":attr.string_list(),
  # The name of the nuget package
  "package":attr.string(mandatory=True),
  # The version of the nuget package
  "version":attr.string(mandatory=True),
  # The verbosity level
  "verbosity": attr.string(
    values=["normal", "quiet", "detailed"],
    default="normal",
  ),
  # Reference to the mono binary
  "mono_exe":attr.label(
    executable=True,
    default=Label("@mono//bin:mono"),
    cfg="host",
  ),
  # Reference to the nuget.exe file
  "nuget_exe":attr.label(
    default=Label("@nuget//:nuget.exe"),
  ),
}

nuget_package = repository_rule(
  implementation=_nuget_package_impl,
  attrs=_nuget_package_attrs,
)
"""Fetches a nuget package as an external dependency.

Args:
  package_sources: list of sources to use for nuget package feeds.
  package: name of the nuget package.
  version: version of the nuget package (e.g. 0.1.2)
  mono_exe: optional label to the mono executable.
  nuget_exe: optional label to the nuget.exe file.
"""

def _new_nuget_package_impl(repository_ctx):
  build_file = repository_ctx.attr.build_file
  build_file_content = repository_ctx.attr.build_file_content
  if not (build_file_content or build_file):
    fail("build_file or build_file_content is required")
  _nuget_package_impl(repository_ctx, build_file, build_file_content)

new_nuget_package = repository_rule(
  implementation=_new_nuget_package_impl,
  attrs=_nuget_package_attrs + {
    "build_file": attr.label(
      allow_files = True,
    ),
    "build_file_content": attr.string(),
  })
"""Fetches a nuget package as an external dependency with custom BUILD content.

Args:
  package_sources: list of sources to use for nuget package feeds.
  package: name of the nuget package.
  version: version of the nuget package (e.g. 0.1.2)
  mono_exe: optional label to the mono executable.
  nuget_exe: optional label to the nuget.exe file.
  build_file: label to the BUILD file.
  build_file_content: content for the BUILD file.
"""

csharp_autoconf = repository_rule(
    implementation = _csharp_autoconf,
    local = True,
)


def _execute(repository_ctx, args, fail_on_error = True, print_stdout = False):
  result = repository_ctx.execute(args)
  if result.return_code and fail_on_error:
    print("ARGS: %s" % args)
    print("FAILURE CODE: %s" % result.return_code)
    print("STDOUT: %s" % result.stdout)
    print("STDERR: %s" % result.stderr)
    fail("%s failed (%s): %s" % (" ".join(args), result.return_code, result.stderr))
  if print_stdout:
    print("%s stdout: %s" % (" ".join(args), result.stdout))
  return result


def _mono_osx_repository_impl(repository_ctx):
  dirname = "%s" % repository_ctx.path("")
  if dirname.startswith("//"):
    dirname = dirname[1:]

  pkgutil = repository_ctx.which("pkgutil")
  if not pkgutil:
    fail("pkgutil not found in PATH")
  tar = repository_ctx.which("tar")
  if not tar:
    fail("tar not found in PATH")

  # Download the package (353MB)
  repository_ctx.download(
    "https://download.mono-project.com/archive/4.8.1/macos-10-universal/MonoFramework-MDK-4.8.1.0.macos10.xamarin.universal.pkg",
    #"http://localhost:2017/mono.pkg",
    "mono.pkg",
    "5f1ee8314e3b61e2c81fc95cae4c6610a467adc2bb1299ab44c9b4a568bc0efd")

  # Extract it with pkgutil (macos only)
  _execute(repository_ctx, ["pkgutil", "--expand", "mono.pkg", "mono"])

  # Untar the embedded 'Payload' blob to ./Library/...
  _execute(repository_ctx, ["tar", "-xf", "mono/mono.pkg/Payload"])

  # Remove prior symlink if it exists (should only be during development of this function!)
  #_execute(repository_ctx, ["rm", "bin"])

  # Link Library/.../bin here.
  repository_ctx.symlink("Library/Frameworks/Mono.framework/Versions/4.8.1/bin", "bin")

  # Find and replace.
  pattern = ["Library", "Frameworks", "Mono.framework"]
  replacement = dirname.split("/") + pattern
  sed_expression = "s|%s|%s|g" % ("/".join([""] + pattern), "/".join(replacement))
  find_and_replace = [
    "find", "Library", # starting in Library directory
    "-type", "f", # only match regular files

    # "-exec", "grep", # execute grep on all matches
    # "-I", # ignore binary files
    # #"-l", '""',
    # "-q", # suppress normal grep output
    # "%s" % "/".join(pattern), # match this string
    # "{}", # matched filename
    # ";", # terminate grep exec (no need to escape it like \;)

    # "-and", # join another find clause
    # "-print", # print matches

    "-exec", "sed", # execute sed on each matched filename
    "-i.bak", # in-place replacement, creating file.bak
    "-e", sed_expression,
    "{}", # matched filename
    ";", # terminate sed exec
  ]
  _execute(repository_ctx, find_and_replace, print_stdout=False)

  # Cleanup 704MB of disk
  _execute(repository_ctx, ["rm", "-rf", "mono/", "mono.pkg"])

  # Finally, create the build file.
  repository_ctx.file("bin/BUILD", """
package(default_visibility = ["//visibility:public"])
exports_files(["mono", "mcs"])
load("@io_bazel_rules_dotnet//dotnet:csharp.bzl", "mono_toolchain")
mono_toolchain(
  name = "toolchain",
  root = "{dirname}/Library/Frameworks/Mono.framework/Versions/4.8.1",
  path = "{dirname}/Library/Frameworks/Mono.framework/Versions/4.8.1/lib/mono/4.5",
)
""".format(dirname=dirname))


def _mono_repository_impl(repository_ctx):
  use_local = repository_ctx.os.environ.get(
    "RULES_DOTNET_USE_LOCAL_MONO", repository_ctx.attr.use_local)
  if use_local or repository_ctx.os.name.find("linux") != -1:
    _csharp_autoconf(repository_ctx)
  elif repository_ctx.os.name.find("mac") != -1:
    _mono_osx_repository_impl(repository_ctx)
  else:
    fail("Unsupported operating system: %s" % repository_ctx.os.name)


mono_package = repository_rule(
  implementation = _mono_repository_impl,
  attrs = {
    "use_local": attr.bool(default=False),
  },
  local = True,
)

def _mono_toolchain_impl(ctx):
  return struct(
    mono_toolchain = struct(
      path = ctx.attr.path,
      root = ctx.attr.root,
      #pkg_config_path = ctx.attr.pkg_config_path,
    )
  )

mono_toolchain = rule(
  implementation = _mono_toolchain_impl,
  attrs = {
    "path": attr.string(mandatory = True),
    "root": attr.string(mandatory = True),
    #"pkg_config_path": attr.string(mandatory = True),
  }
)

def csharp_repositories(use_local_mono=False):
  """Adds the repository rules needed for using the C# rules."""

  # native.new_http_archive(
  #     name = "nunit",
  #     url = "http://bazel-mirror.storage.googleapis.com/github.com/nunit/nunitv2/releases/download/2.6.4/NUnit-2.6.4.zip",
  #     sha256 = "1bd925514f31e7729ccde40a38a512c2accd86895f93465f3dfe6d0b593d7170",
  #     type = "zip",
  #     # This is a little weird but is necessary for the build file reference to
  #     # work when Workspaces import this using a repository rule.
  #     build_file = str(Label("//dotnet:nunit.BUILD")),
  # )

  # native.new_http_archive(
  #     name = "nunit",
  #     url = "https://github.com/nunit/nunit/archive/757888f46292ceea9273da35a9b3122a8c57c0e3.zip", # 3.6.1
  #     sha256 = "43530d0e73d719652553b1553a24cd1286ff1ca85d49c8d3975683d77659736d",
  #     strip_prefix = "nunit-757888f46292ceea9273da35a9b3122a8c57c0e3",
  #     build_file = str(Label("//dotnet:nunit.BUILD")),
  # )

  native.new_http_archive(
    name = "nunit",
    url = "https://github.com/nunit/nunit-console/releases/download/3.6.1/NUnit.Console-3.6.1.zip",
    sha256 = "3a177506699282d5c9e720be8bab8f9c0cb925e0e78acd335fbf6798b7095648",
    build_file = str(Label("//dotnet:nunit.BUILD")),
  )

  native.new_http_archive(
    name = "nunit_framework",
    url = "https://github.com/nunit/nunit/releases/download/3.6.1/NUnit.Framework-3.6.1.zip",
    sha256 = "6de9b2ca2d2866859ba02167c5e436386ac99eebb16ccd548e365e24b61041a8",
    build_file = str(Label("//dotnet:nunit_framework.BUILD")),
  )

  # native.new_http_archive(
  #   name = "nunit",
  #   url = "https://github.com/nunit/nunit-console/releases/download/3.5/NUnit.Console-3.5.0.zip",
  #   sha256 = "1316b2f6d27edc1b51a8c8ee2d93eef9105c3270cabd7bbb976a3977eba90704",
  #   build_file = str(Label("//dotnet:nunit.BUILD")),
  # )

  # native.new_http_archive(
  #   name = "nunit_framework",
  #   url = "https://github.com/nunit/nunit/releases/download/3.5/NUnit-3.5.0.zip",
  #   sha256 = "8b59a60cf3c55f78001b0a8aa09d47818206f860e929f696d3d93f33ab1adcd0",
  #   build_file = str(Label("//dotnet:nunit_framework.BUILD")),
  # )


  # native.new_http_archive(
  #   name = "nunit_console",
  #   url = "https://github.com/nunit/nunit-console/releases/download/3.6.1/NUnit.Console-3.6.1.zip",
  #   sha256 = "6de9b2ca2d2866859ba02167c5e436386ac99eebb16ccd548e365e24b61041a8",
  #   build_file = str(Label("//dotnet:nunit-console.BUILD")),
  # )

  native.new_http_archive(
      name = "nuget",
      url = "https://github.com/mono/nuget-binary/archive/fb441016aa5d878e34da79665c3e677c9fef8a00.zip", # Mar 15, 2017
      sha256 = "90484e1d01181f59f41d91d3524f955904ac857b26a45798f8799a8144932e9c",
      strip_prefix = "nuget-binary-fb441016aa5d878e34da79665c3e677c9fef8a00",
      type = "zip",
      build_file_content = """
      package(default_visibility = ["//visibility:public"])
      exports_files(["nuget.exe"])
      """
  )

  mono_package(name="mono", use_local=use_local_mono)
