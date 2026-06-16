To run this code:
1.	download the repository
2.	put it in a folder somewhere
3.	install Julia and VS Code https://www.julia-vscode.org/docs/dev/gettingstarted/
4.	open VS Code and then open the folder you put the repository in
5.	type Alt+J, Alt+O to activate the Julia REPL, 
6.	then do this:
 
using Pkg # the package manager for Julia
Pkg.activate(@__DIR__) # activate the current directory to be your environment
Pkg.instantiate() # install all the packages in the Manifest.toml file
