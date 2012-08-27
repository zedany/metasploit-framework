##
# $Id$
# $Revision$
##

require 'rex/ui/text/table'

module Msf

class Plugin::Alias < Msf::Plugin
	class AliasCommandDispatcher
		include Msf::Ui::Console::CommandDispatcher

		attr_reader :aliases
		def initialize(driver)
			super(driver)
			@aliases = {}
		end

		def name
			"Alias"
		end

		@@alias_opts = Rex::Parser::Arguments.new(
			"-h" => [ false, "Help banner."                    ],
			"-c" => [ true, "Clear an alias (* to clear all)."],
			"-f" => [ true,  "Force an alias assignment."      ]
		)
		#
		# Returns the hash of commands supported by this dispatcher.
		#
		def commands # driver.dispatcher_stack[3].commands
			{
				"alias" => "create or view an alias."
	#			"alias_clear" => "clear an alias (or all aliases).",
	#			"alias_force" => "Force an alias (such as to override)"
			}.merge(aliases) # make aliased commands available as commands of their own
		end

		#
		# the main alias command handler
		#
		# usage: alias [options] [name [value]]
		def cmd_alias(*args)
			# we parse args manually instead of using @@alias.opts.parse to handle special cases
			case args.length
			when 0 # print the list of current aliases
				if @aliases.length == 0 
					return print_status("No aliases currently defined")
				else
					tbl = Rex::Ui::Text::Table.new(
						'Header'  => "Current Aliases",
						'Prefix'  => "\n",
						'Postfix' => "\n",
						'Columns' => [ 'Alias Name', 'Alias Value' ]
					)
					@aliases.each_pair do |key,val|
						tbl << [key,val]
					end
					return print(tbl.to_s)
				end
			when 1 # display the alias if one matches this name (or help)
				return cmd_alias_help if args[0] == "-h" or args[0] == "--help"
				if @aliases.keys.include?(args[0])
					print_status("\'#{args[0]}\' is aliased to \'#{@aliases[args[0]]}\'")
				else
					print_status("\'#{args[0]}\' is not currently aliased")
				end
			else # let's see if we can assign or clear the alias
				force = false
				clear = false
				# if using -f or -c, they must be the first arg, because -f/-c may also show up in the alias
				# value so we can't do something like if args.include("-f") or delete_if etc
				# we sould never have to force and clear simultaneously.
				if args[0] == "-f"
					force = true
					args.shift
				elsif args[0] == "-c"
					clear = true
					args.shift
				end
				name = args.shift
				print_good "The alias name is #{name}"
				if clear
					# clear all aliases if "*"
					if name == "*"
						@aliases.keys.each do |a|
							deregister_alias(a)
						end
						print_status "Cleared all aliases"
					else # clear the named alias if it exists
						print_status "Checking alias #{name} for clear"
						deregister_alias(name) if @aliases.keys.include?(name)
						print_status "Cleared alias #{name}"
					end
					return
				end
				# smash everything that's left together
				value = args.join(" ")

				if is_valid_alias?(name,value)
					if force or (not Rex::FileUtils.find_full_path(name) and not @aliases.keys.include?(name))
						register_alias(name, value)
					else
						print_error("#{name} already exists as system command or current alias, use -f to force")
					end
				else
					print_error("\'#{name}\' is not a permitted name or \'#{value}\' is not a valid/permitted console or system command")
				end
			end
		end

		def cmd_alias_help
			print_line "Usage: alias [options] [name [value]]"
			print_line
			print(@@alias_opts.usage())	
		end

		#
		# Tab completion for the alias command
		#
		def cmd_alias_tabs(str, words)
			if words.length <= 1
				return @@alias_opts.fmt.keys + tab_complete_aliases_and_commands(str, words)
			else
				return tab_complete_aliases_and_commands(str, words)
			end
		end

		private
		#
		# do everything needed to add an alias of +name+ having the value +value+
		#
		def register_alias(name, value)
			#TODO:  begin rescue?
			#TODO:  security concerns since we are using eval

			# define some class instance methods
			self.class_eval do
				# define a class instance method that will respond for the alias
				define_method "cmd_#{name}" do |*args|
					# just replace the alias w/the alias' value and run that
					driver.run_single("#{value} #{args.join(' ')}")
				end
				# define a class instance method that will tab complete the aliased command
				# we just proxy to the top-level tab complete function and let them handle it
				define_method "cmd_#{name}_tabs" do |str, words|
					#print_good "Creating cmd_#{name}_tabs as driver.tab_complete(#{value} #{words.join(' ')})"
					#driver.tab_complete("MONKEY")
					words.delete(name)
					driver.tab_complete("#{value} #{words.join(' ')}")
				end
				# we don't need a cmd_#{name}_help method, we just let the original handle that
			end
			# add the alias to the list 
			@aliases[name] = value
		end

		#
		# do everything required to remove an alias of name +name+
		#
		def deregister_alias(name)
			self.class_eval do
				# remove the methods we defined for this alias
				remove_method("cmd_#{name}")
				remove_method("cmd_#{name}_tab")
			end
		end

		#
		# Validate a proposed alias
		#
		def is_valid_alias?(name,value)
			# some "bad words" to avoid for the value.  value would have to not match these regexes
			# this is just basic idiot protection, it's not meant to be "undefeatable"
			value.strip!
			bad_words = [/^rm +(-rf|-r +-f|-f +-r) +\/+.*$/, /^msfconsole$/]
			bad_words.each do |regex|
				# don't mess around, just return false if we match
				return false if value =~ regex
			end
			# we're only gonna validate the first part of the cmd, e.g. just ls from "ls -lh"
			value = value.split(" ").first
			valid_value = false

			# value is considered valid if it's a ref to a valid console command or
			#  a system executable or existing alias

			# gather all the current commands the driver's dispatcher's have & check 'em
			driver.dispatcher_stack.each do |dispatcher|
				next unless dispatcher.respond_to?(:commands)
				next if (dispatcher.commands.nil?)
				next if (dispatcher.commands.length == 0)

				if dispatcher.respond_to?("cmd_#{value.split(" ").first}")
					valid_value = true
					break
				end
			end
			if not valid_value # then check elsewhere
				if @aliases.keys.include?(value)
					valid_value = true
				else
					[value, value+".exe"].each do |cmd|
						if Rex::FileUtils.find_full_path(cmd)
							valid_value = true
						end
					end
				end
			end
			# go ahead and return false at this point if the value isn't valid
			return false if not valid_value

			# we don't check if this alias name exists or if it's a console command already etc as
			#  -f can override that so those need to be checked externally.
			#  We pretty much just check to see if the name is sane
			valid_name = true
			name.strip!
			bad_words = [/^alias$/,/\*/]
			# there are probably a bunch of others that need to be added here.  We prevent the user
			#  from naming the alias "alias" cuz they can end up unable to clear the aliases
			# for example you 'alias -f set unse't and then 'alias -f alias sessions', now you're 
			#  screwed.  This prevents you from aliasing alias to alias -f etc, but no biggie.
			bad_words.each do |regex|
				# don't mess around, just return false in this case, prevents wasted processing
				return false if name =~ regex
			end

			return valid_name
		end

		#
		# Provide tab completion list for aliases and commands
		#
		def tab_complete_aliases_and_commands(str, words)
			items = []
			items.concat(driver.commands.keys) if driver.respond_to?('commands')
			items.concat(@aliases.keys)
			items
		end

	end # end AliasCommandDispatcher class

	#
	# The constructor is called when an instance of the plugin is created.  The
	# framework instance that the plugin is being associated with is passed in
	# the framework parameter.  Plugins should call the parent constructor when
	# inheriting from Msf::Plugin to ensure that the framework attribute on
	# their instance gets set.
	#
	attr_accessor :controller
	
	def initialize(framework, opts)
		super

		## Register the commands above
		add_console_dispatcher(AliasCommandDispatcher)
	end


	#
	# The cleanup routine for plugins gives them a chance to undo any actions
	# they may have done to the framework.  For instance, if a console
	# dispatcher was added, then it should be removed in the cleanup routine.
	#
	def cleanup
		# If we had previously registered a console dispatcher with the console,
		# deregister it now.
		remove_console_dispatcher('Alias')
	end

	#
	# This method returns a short, friendly name for the plugin.
	#
	def name
		"Alias"
	end

	#
	# This method returns a brief description of the plugin.  It should be no
	# more than 60 characters, but there are no hard limits.
	#
	def desc
		"Adds the ability to alias console commands"
	end

end ## End Plugin Class
end ## End Module	