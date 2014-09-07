#!/usr/bin/env zsh
# Usage: ./cabal2pkgbuild.sh <HACKAGE_PACKAGES_FILE> <MODE>
usage="Usage: ./cabal2pkgbuild.sh <HACKAGE_PACKAGES_FILE> <MODE>"

# Exit immediately if any errors are found
setopt errexit
# Avoid "no matches found" error if a file does not exist; see
# http://www.zsh.org/mla/users/2008/msg01139.html
setopt local_options no_nomatch

pacman_to_cblrepo () {
	# When invoking `pacman -Q PKGNAME`, PKGNAME must be lowercase.
	pacman_friendly=(${@:l})
	pvs=$(pacman -Q ${pacman_friendly/#/haskell-})
	versions=()
	typeset -A pkgs1
	pkgs1=()
	pkgs2=()
	pkgs3=()
	for pv in ${(f)pvs}; do
		v=$(echo $pv | sed -e 's/^.\+ //' -e 's/-/,/')
		versions+=($v)
	done

	# Use an associative array for saner substitutions.
	for (( i = 1; i <= $#@; i++ )) do
		pkgs1+=($@[i] $versions[i])
	done

	for k in ${(@k)pkgs1}; do
		package="${k#haskell-},${pkgs1[$k]/-/,}"
		pkgs2+=($package)
	done

	# We have to sort $pkgs2, because the array ordering is lost when we use
	# Zsh's associative array with `typeset -A pkgs1`.
	pkgs3=(${(o)pkgs2})
	for pkg in $pkgs3; do
		echo " " $pkg
	done

	echo "cblrepo add" ${pkgs3/#/--distro-pkg }
	eval "cblrepo add" ${pkgs3/#/--distro-pkg }
}

if [[ -z $1 ]]; then
	echo $usage
	exit 1
fi
if [[ ! -f $1 ]]; then
	echo "\`$1' does not exist or is not a regular file"
	exit 1
fi
if [[ -z $2 ]]; then
	echo $usage
	exit 1
fi

ghc_pkgs=()
ghc_pkgs_lower_name_only=()
hackage_pkgs=()

hackage_url="http://hackage.haskell.org"
hackage_packages_file=($(<$1))
hackage_lowered=($hackage_packages_file:l)

mode=$2

case $mode in
	### Remove any old cblrepo.db file. ###
	(initdb|initdb-sync)
	rm -fv cblrepo.db

	# Add `ghc` itself
	ghcversion=$(pacman -Q ghc | cut -d " " -f2 | sed 's/-/,/')
	command="cblrepo add --distro-pkg ghc,$ghcversion"
	# Tell user what we are going to do.
	echo $command
	# Actually execute the command.
	eval $command

	# Add packages provided by GHC

	# Pacman provides information about which modules are exposed by installing the
	# 'ghc' package. We put each package into an array.
	provided=($(pacman -Qi ghc | grep Provides | cut -d ":" -f2))

	echo "GHC packages to be added:"
	for p in $provided; do
		# Change the syntax to be compatible with cblrepo. The `cut` command here
		# removes the 'haskell-' prefix for each package, and `sed` here replaces
		# each '=' sign with a ',', as per cblrepo's requirements.
		package=$(echo $p | cut -c9- | sed 's/=.\+//')
		version=$(echo $p | cut -c9- | sed 's/^.\+=//')
		ghc_pkgs+=($package,$version)
		ghc_pkgs_lower_name_only+=($package)
		echo " " $package,$version
	done
	echo "cblrepo add" ${ghc_pkgs/#/--ghc-pkg }
	eval "cblrepo add" ${ghc_pkgs/#/--ghc-pkg }
	echo

	# Add packages installed by the user from [haskell-core] or some other Arch
	# Linux repository.
	pacman_hackage=($(pacman -Qq | grep "^haskell-" | sed 's/^haskell-//'))
	# Filter out those packages that were installed from Hackage using this very
	# same script (in Arch Linux, the hackage packages, once installed, are in
	# the format `haskell-<lowercased_package_name>'). This way, we avoid
	# duplicate definitions and the packages added with --distro-pkg will really
	# be those packages *only* available from the distribution's official
	# haskell repository.
	distro=(${pacman_hackage:|hackage_lowered})

	hackage_only=(${pacman_hackage:|distro})
	echo hackage_only: $hackage_only
	echo
	echo distro: $distro
	echo

	# Some packages have upper case letters in their names, but pacman only uses
	# lowercase. To make cblrepo understand that, e.g., `QuickCheck` is the
	# same as `quickcheck`, we add the uppercase version, NOT the lowercase version.
	ghcpkgs_upper=(
		$(ghc-pkg list --names-only --simple-output\
			| tr ' ' '\n'\
			| grep '[A-Z]')
	)
	ghcpkgs_upper_lowered=(${ghcpkgs_upper:l})
	echo ghcpkgs_upper_lowered: $ghcpkgs_upper_lowered
	echo

	# All pacman-recognized packages (haskell-*), but without the uppercase ones
	# from `ghc-pkg list`.
	distro_no_upper=(${distro:|ghcpkgs_upper_lowered})
	# All pacman-recognized packages (haskell-*), which also happen to be uppercase.
	distro_upper_only=(${distro:|distro_no_upper})
	echo distro_no_upper: $distro_no_upper
	echo
	echo distro_upper_only: $distro_upper_only
	echo

	# Same as distro_upper_only, but with the actual uppercase names.
	distro_upper_actual=()
	for p in $ghcpkgs_upper; do
		p_lower=${p:l}
		if [[ -z "${distro[(r)$p_lower]}" ]]; then
			continue
		fi
		distro_upper_actual+=($p)
	done

	echo distro_upper_actual: $distro_upper_actual
	echo

	echo "Distribution (originally lowercase) packages to be added (1/2):"
	[[ -n $distro_no_upper ]] && pacman_to_cblrepo $distro_no_upper

	echo "Distribution (originally mixed case) packages to be added (2/2):"
	[[ -n $distro_upper_actual ]] && pacman_to_cblrepo $distro_upper_actual

	# We sync cblrepo with Hackage if the user requested it. This is an
	# important step because we rely on cblrepo's knowledge of Hackage to
	# download the latest packages. If cblrepo's cache is out of date, then this
	# script's "latest" Hackage packages will also be out of date.
	if [[ $mode == initdb-sync ]]; then
		# Sync cblrepo with Hackage
		echo -n "Syncing cblrepo with Hackage..."
		cblrepo sync
		echo "done"
	fi

	# Add packages from Hackage
	echo "Adding packages from \`$1'"
	mkdir -p cache
	cabal_files=()
	cabal_latest=($(cblrepo versions -l $hackage_packages_file))
	cabal_urls=($(cblrepo urls $cabal_latest))
	typeset -A aria_hash
	aria_hash=()
	for (( i = 1; i <= $#cabal_urls; i++ )) do
		url=$cabal_urls[i]
		name_version=${cabal_latest[i]/,/-}
		cabal_file="cache/$name_version.cabal"
		cabal_files+=($cabal_file)
		aria_hash+=($cabal_file "$url\n  out=$cabal_file")
	done

	for (( i = 1; i <= $#cabal_files; i++ )) do
		# If the proposed cabal file already exists in the cache, remove it from
		# the downloads list.
		[[ -e $cabal_files[i] ]] && unset "aria_hash[$cabal_files[i]]"
	done

	echo
	echo "Downloading cabal files from Hackage..."
	if [[ -n $aria_hash ]]; then
		echo ${(F)aria_hash}
		echo "Starting aria2c..."
		echo ${(F)aria_hash} | aria2c -i -
	else
		echo "Nothing to download."
		echo
	fi


	echo "cblrepo add --patchdir patch" ${cabal_files/#/-f }
	eval "cblrepo add --patchdir patch" ${cabal_files/#/-f }

	# Link the generated cblrepo.db file into ~/.cblrepo
	ln -sf $PWD/cblrepo.db ~/.cblrepo/cblrepo.db
	;;
	### Generate PKGBUILD files for Hackage packages ###
	(pkgbuild)

	# Remove any old packages.
	echo "Deleting old PKGBUILD directories..."
	rm -rfv haskell-*

	echo "cblrepo pkgbuild --patchdir patch $hackage_packages_file"
	eval "cblrepo pkgbuild --patchdir patch $hackage_packages_file"
	;;
	### Create Arch Linux packages for the Hackage packages ###
	(makepkg)
	for pkg in ${hackage_lowered}; do
		hpkg=haskell-$pkg
		install_pkg=0
		while true; do
			read "reply?Make and install package \`$pkg'? (y/n): "
			case $reply in
				[Yy])
					install_pkg=1
					break
					;;
				[Nn]) break ;;
				*) printf '%s\n' 'Please answer y or n.' ;;
			esac
		done

		if (( $install_pkg )); then
			cd $hpkg
			echo $hpkg
			makepkg -sif
			cd ..
			echo
			echo "  Finished making/installing package \`$hpkg'"
			echo
		fi
	done
	;;
	*)
	help_msg=(
		"Unrecognized <MODE>; valid ones are:"
		"initdb initdb-sync pkgbuild makepkg"
		)
	echo $help_msg
	;;
esac
