#!/usr/bin/env zsh
# Usage: ./cabal2pkgbuild.sh <HACKAGE_PACKAGES_FILE> <MODE>
usage="Usage: ./cabal2pkgbuild.sh <HACKAGE_PACKAGES_FILE> <MODE>"

# Exit immediately if any errors are found
setopt errexit
# Avoid "no matches found" error if a file does not exist; see
# http://www.zsh.org/mla/users/2008/msg01139.html
setopt local_options no_nomatch

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

hackage_url="http://hackage.haskell.org"
hackage_packages_file=($(<$1))
hackage_lowercased=($hackage_packages_file:l)

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

	for p in $provided; do
		# Change the syntax to be compatible with cblrepo. The `cut` command here
		# removes the 'haskell-' prefix for each package, and `sed` here replaces
		# each '=' sign with a ',', as per cblrepo's requirements.
		package=$(echo $p | cut -c9- | sed 's/=/,/')
		command="cblrepo add --ghc-pkg $package"
		echo $command
		eval $command
	done

	# Add packages installed by the user from [haskell-core] or some other Arch
	# Linux repository
	installed=($(pacman -Qq | grep "^haskell-" | sed 's/^haskell-//'))
	# Filter out those packages that were installed from Hackage using this very
	# same script (in Arch Linux, the hackage packages, once installed, are in
	# the format `haskell-<lowercased_package_name>'). This way, we avoid
	# duplicate definitions and the packages added with --distro-pkg will really
	# be those packages available from the distribution's official haskell
	# repository.
	installed_filtered=(${installed:|hackage_lowercased})

	# Some packages have upper case letters in their names, but pacman only
	# uses lower case, so it is necessary to filter these packages and add them
	# to the database with their proper, mixed case names.
	upperpkgs=(
		$(ghc-pkg list --names-only --simple-output\
			| tr ' ' '\n'\
			| grep '[A-Z]')
	)
	upperpkgslower=(${upperpkgs:l})
	# The following are the lower case packages
	installed_filtered_lower=(${installed_filtered:|upperpkgslower})
	# ghc-pkg, but not pacman, lists the following
	installed_filtered_notpacman=(${upperpkgslower:|installed_filtered})
	# The following are the upper case packages
	installed_filtered_upper=(${upperpkgslower:|installed_filtered_notpacman})

	for p in $installed_filtered_lower; do
		version=$(pacman -Q haskell-$p | cut -d " " -f2 | sed 's/-/,/')
		command="cblrepo add --distro-pkg $p,$version"
		echo $command
		eval $command
	done

	for pg in $upperpkgs; do
		# Check if lower case version of name is in correct array, and return
		# "" if not
		p="${pg:l}"
		# Do not carry on if there is no package in the pacman list
		if [[ -z ${installed_filtered_upper[(r)$p]} ]]; then
			continue
		fi
		version=$(pacman -Q haskell-$p | cut -d " " -f2 | sed 's/-/,/')
		command="cblrepo add --distro-pkg $pg,$version"
		echo $command
		eval $command
	done

	if [[ $mode == initdb-sync ]]; then
		# Sync cblrepo with Hackage
		echo -n "Syncing cblrepo with Hackage..."
		cblrepo sync
		echo "done"
	fi

	# Add packages from Hackage
	mkdir -p cache
	for hp in $hackage_packages_file; do
		# Grab latest version of package
		cabal_file=$(curl -s $hackage_url/package/$hp\
			| grep -ioE "source package[)<>/lia href=\"]+\/package\/.+\.cabal"\
			| grep -ioE "\/package.+")
		[[ ! -e cache$cabal_file ]]\
			&& curl -# -C - -f $hackage_url$cabal_file\
			-o cache$cabal_file --create-dirs
		command="cblrepo add --patchdir patch -f cache$cabal_file"
		echo $command
		eval $command
	done

	# Link the generated cblrepo.db file into ~/.cblrepo
	ln -sf $PWD/cblrepo.db ~/.cblrepo/cblrepo.db
	;;
	### Generate PKGBUILD files for Hackage packages ###
	(pkgbuild)

	# Remove any old packages.
	echo "Deleting old PKGBUILD directories..."
	rm -rfv haskell-*

	i=1
	for hp in ${hackage_packages_file}; do
		command="cblrepo pkgbuild --patchdir patch $hp"
		echo "($i/${#hackage_packages_file}) $command"
		eval $command
		(( i+=1 ))
	done
	;;
	### Create Arch Linux packages for the Hackage packages ###
	(makepkg)
	for pkg in ${hackage_lowercased}; do
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
