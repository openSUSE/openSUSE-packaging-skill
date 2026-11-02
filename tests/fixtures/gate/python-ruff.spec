# The header of devel:languages:python/python-ruff's spec, the order most python
# _multibuild specs use: the flavor's psuffix is defined before the base's.
%global flavor @BUILD_FLAVOR@%{nil}
%if "%{flavor}" == "test"
%define psuffix -test
%global debug_package %{nil}
%bcond_without test
%else
%define psuffix %{nil}
%bcond_with test
%endif
%define origname python-ruff
%bcond_without libalternatives
Name:           %{origname}%{psuffix}
Version:        0.17.3
Release:        0
Summary:        An extremely fast Python linter, written in Rust
License:        MIT AND MPL-2.0
