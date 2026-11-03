# The Name of X11:Utilities/halloween-openSUSE's spec: psuffix is defined for the
# firefox flavor only, so %{?psuffix} is empty in the base build.
%define base_name halloween-openSUSE
%global flavor @BUILD_FLAVOR@%{nil}
%if "%{flavor}" == "firefox"
%define psuffix -firefox-theme
%endif
Name:           %{base_name}%{?psuffix}
Version:        2026.10.6
Release:        0
Summary:        Halloween theme for openSUSE
License:        CC-BY-SA-4.0
