require 'pathname'

module Padrino
  ##
  # High performance source code reloader middleware
  #
  module Reloader
    ##
    # This reloader is suited for use in a many environments because each file
    # will only be checked once and only one system call to stat(2) is made.
    #
    # Please note that this will not reload files in the background, and does so
    # only when explicitly invoked.
    #

    # The modification times for every file in a project.
    MTIMES          = {}

    class << self
      ##
      # Specified folders can be excluded from the code reload detection process.
      # Default excluded directories at Padrino.root are: test, spec, features, tmp, config, db and public
      #
      def exclude
        @_exclude ||= %w(test spec tmp features config public db).map { |path| Padrino.root(path) }
      end

      ##
      # Specified constants can be excluded from the code unloading process.
      #
      def exclude_constants
        @_exclude_constants ||= []
      end

      ##
      # Specified constants can be configured to be reloaded on every request.
      # Default included constants are: [none]
      #
      def include_constants
        @_include_constants ||= []
      end

      ##
      # Reload all files with changes detected.
      #
      def reload!
        # Detect changed files
        rotation do |file, mtime|
          # Retrive the last modified time
          new_file = MTIMES[file].nil?
          previous_mtime = MTIMES[file] ||= mtime
          logger.devel "Detected a new file #{file}" if new_file
          # We skip to next file if it is not new and not modified
          next unless new_file || mtime > previous_mtime
          # Now we can reload our file
          apps = mounted_apps_of(file)
          if apps.present?
            apps.each { |app| app.app_obj.reload! }
          else
            safe_load(file, :force => new_file)
            # Reload also apps
            Padrino.mounted_apps.each do |app|
              app.app_obj.reload! if app.app_obj.dependencies.include?(file)
            end
          end
        end
      end

      def remove_feature(file)
        $LOADED_FEATURES.delete(file) unless feature_excluded?(file)
      end
      ##
      # Remove files and classes loaded with stat
      #
      def clear!
        MTIMES.clear
        Storage.clear!
      end

      ##
      # Returns true if any file changes are detected and populates the MTIMES cache
      #
      def changed?
        changed = false
        rotation do |file, mtime|
          new_file = MTIMES[file].nil?
          previous_mtime = MTIMES[file] ||= mtime
          changed = true if new_file || mtime > previous_mtime
        end
        changed
      end
      alias :run! :changed?

      ##
      # We lock dependencies sets to prevent reloading of protected constants
      #
      def lock!
        klasses = ObjectSpace.classes.map { |klass| klass.name.to_s.split("::")[0] }.uniq
        klasses = klasses | Padrino.mounted_apps.map { |app| app.app_class }
        Padrino::Reloader.exclude_constants.concat(klasses)
      end

      def safe_load(file, options={})
        began_at = Time.now
        file     = figure_path(file)
        return unless options[:force] || file_changed?(file)
        return require(file) if feature_excluded?(file)

        Storage.prepare(file) # might call #safe_load recursively
        logger.devel(file_new?(file) ? :loading : :reload, began_at, file)
        begin
          with_silence{ require(file) }
          Storage.commit(file)
          update_modification_time(file)
        rescue Exception => exception
          unless options[:cyclic]
            logger.error "Failed to load #{file}; removing partially defined constants"
          end
          Storage.rollback(file)
          raise
        end
      end

      def feature_excluded?(file)
        !file.start_with?(Padrino.root) || exclude.any?{ |excluded_path| file.start_with?(excluded_path) }
      end

      def update_modification_time(file)
        MTIMES[file] = File.mtime(file)
      end

      ###
      # Returns true if the file is new or it's modification time changed.
      #
      def file_changed?(file)
        file_new?(file) || File.mtime(file) > MTIMES[file]
      end

      ###
      # Returns true if the file is new.
      #
      def file_new?(file)
        MTIMES[file].nil?
      end

      def with_silence
        verbosity_level, $-v = $-v, nil
        yield
      ensure
        $-v = verbosity_level
      end


      ##
      # Returns true if the file is defined in our padrino root
      #
      def figure_path(file)
        return file if Pathname.new(file).absolute?
        $:.each do |path|
          found = File.join(path, file)
          return File.expand_path(found) if File.exist?(found)
        end
        file
      end

      ##
      # Removes the specified class and constant.
      #
      def remove_constant(const)
        return if exclude_constants.compact.uniq.any? { |c| (const.to_s =~ %r{^#{Regexp.escape(c)}}) } &&
            !include_constants.compact.uniq.any? { |c| (const.to_s =~ %r{^#{Regexp.escape(c)}}) }
        begin
          parts  = const.to_s.split("::")
          base   = parts.size == 1 ? Object : parts[0..-2].join("::").constantize
          object = parts[-1].to_s
          base.send(:remove_const, object)
          logger.devel "Removed constant: #{const}"
        rescue NameError; end
      end

      private
      ##
      # Return the mounted_apps providing the app location
      # Can be an array because in one app.rb we can define multiple Padrino::Appplications
      #
      def mounted_apps_of(file)
        file = figure_path(file)
        Padrino.mounted_apps.find_all { |app| File.identical?(file, app.app_file) }
      end

      ##
      # Returns true if file is in our Padrino.root
      #
      def in_root?(file)
        # This is better but slow:
        #   Pathname.new(Padrino.root).find { |f| File.identical?(Padrino.root(f), figure_path(file)) }
        figure_path(file) =~ %r{^#{Regexp.escape(Padrino.root)}}
      end

      ##
      # Searches Ruby files in your +Padrino.load_paths+ , Padrino::Application.load_paths
      # and monitors them for any changes.
      #
      def rotation
        files  = Padrino.load_paths.map { |path| Dir["#{path}/**/*.rb"] }.flatten
        files  = files | Padrino.mounted_apps.map { |app| app.app_file }
        files  = files | Padrino.mounted_apps.map { |app| app.app_obj.dependencies }.flatten
        files.uniq.map { |file|
          file = File.expand_path(file)
          next if Padrino::Reloader.exclude.any? { |base| file =~ %r{^#{Regexp.escape(base)}} } || !File.exist?(file)
          yield(file, File.mtime(file))
        }.compact
      end
    end # self

    ##
    # This class acts as a Rack middleware to be added to the application stack. This middleware performs a
    # check and reload for source files at the start of each request, but also respects a specified cool down time
    # during which no further action will be taken.
    #
    class Rack
      def initialize(app, cooldown=1)
        @app = app
        @cooldown = cooldown
        @last = (Time.now - cooldown)
      end

      # Invoked in order to perform the reload as part of the request stack.
      def call(env)
        if @cooldown && Time.now > @last + @cooldown
          Thread.list.size > 1 ? Thread.exclusive { Padrino.reload! } : Padrino.reload!
          @last = Time.now
        end
        @app.call(env)
      end
    end
  end # Reloader
end # Padrino

module Padrino
  module Reloader
    module Storage
      extend self

      @constants = Set.new

      def clear!
        files.each_key do |file|
          remove(file)
          Reloader.remove_feature(file)
        end
        @files = {}
      end

      def remove(name)
        file = files[name] || return
        file[:constants].each{ |constant| Reloader.remove_constant(constant) }
        file[:features].each{ |feature| Reloader.remove_feature(feature) }
        files.delete(name)
      end

      def prepare(name)
        file = remove(name)
        @old_entries ||= {}
        if @constants.empty?
          @constants.merge(ObjectSpace.classes)
          @old_entries[name] = {
              :constants => @constants,
              :features  => old_features = Set.new($LOADED_FEATURES.dup)
          }
        else
          @old_entries[name] = {
              :constants => @constants,
              :features  => old_features = Set.new($LOADED_FEATURES.dup)
          }
        end
        features = file && file[:features] || []
        features.each{ |feature| Reloader.safe_load(feature, :force => true) }
        Reloader.remove_feature(name) if old_features.include?(name)
      end

      def commit(name)
        entry = {
            :constants => new_constants = ObjectSpace.new_classes(@old_entries[name][:constants]),
            :features  => Set.new($LOADED_FEATURES) - @old_entries[name][:features] - [name]
        }
        @constants.merge(new_constants)
        files[name] = entry
        @old_entries.delete(name)
      end

      def rollback(name)
        new_constants = ObjectSpace.new_classes(@old_entries[name][:constants])
        @constants.clear
        new_constants.each{ |klass| Reloader.remove_constant(klass) }
        @old_entries.delete(name)
      end

      private

      def files
        @files ||= {}
      end
    end
  end
end

module ObjectSpace
  class << self
    ##
    # Returns all the classes in the object space.
    # Optionally, a block can be passed, for example the following code
    # would return the classes that start with the character "A":
    #
    #  ObjectSpace.classes do |klass|
    #    if klass.to_s[0] == "A"
    #      klass
    #    end
    #  end
    #
    def classes
      rs = Set.new

      ObjectSpace.each_object(Class).each do |klass|
        if block_given?
          if r = yield(klass)
            # add the returned value if the block returns something
            rs << r
          end
        else
          rs << klass
        end
      end

      rs
    end

    ##
    # Returns a list of existing classes that are not included in "snapshot"
    # This method is useful to get the list of new classes that were loaded
    # after an event like requiring a file.
    # Usage:
    #
    #   snapshot = ObjectSpace.classes
    #   # require a file
    #   ObjectSpace.new_classes(snapshot)
    #
    def new_classes(snapshot)
      self.classes do |klass|
        if !snapshot.include?(klass)
          klass
        end
      end
    end
  end
end