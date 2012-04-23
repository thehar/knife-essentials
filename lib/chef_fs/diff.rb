require 'chef_fs/file_system'
require 'chef/json_compat'
require 'tempfile'
require 'fileutils'
require 'digest/md5'
require 'set'

module ChefFS
  class Diff
    def self.calc_checksum(value)
      return nil if value == nil
      Digest::MD5.hexdigest(value)
    end

    def self.diff_files(old_file, new_file)
      #
      # Short-circuit expensive comparison (could be an extra network
      # request) if a pre-calculated checksum is there
      #
      if new_file.respond_to?(:checksum)
        new_checksum = new_file.checksum
      end
      if old_file.respond_to?(:checksum)
        old_checksum = old_file.checksum
      end

      old_value = :not_retrieved
      new_value = :not_retrieved

      if old_checksum || new_checksum
        if !old_checksum
          old_value = read_file_value(old_file)
          if old_value
            old_checksum = calc_checksum(old_value)
          end
        end
        if !new_checksum
          new_value = read_file_value(new_file)
          if new_value
            new_checksum = calc_checksum(new_value)
          end
        end

        # If the checksums are the same, they are the same.  Return.
        return false if old_checksum == new_checksum
      end

      #
      # Grab the values if we don't have them already from calculating checksum
      #
      old_value = read_file_value(old_file) if old_value == :not_retrieved
      new_value = read_file_value(new_file) if new_value == :not_retrieved

      return false if old_value == new_value
      return false if old_value && new_value && !context_aware_diff(old_file, new_file, old_value, new_value)
      return [ true, old_value, new_value ]
    end

    def self.context_aware_diff(old_file, new_file, old_value, new_value)
      # TODO handle errors in reading JSON
      if old_file.content_type == :json || new_file.content_type == :json
        new_value = Chef::JSONCompat.from_json(new_value).to_hash
        old_value = Chef::JSONCompat.from_json(old_value).to_hash

        diff = diff_json(old_file, new_file, old_value, new_value, "")
        #if diff.length > 0
        #  puts "#{new_file.path_for_printing}: Files are different"
        #  diff.each { |message| puts "  #{message}" }
        #end
        diff.length > 0
      else
        true
      end
    end

    def self.diff_json(old_file, new_file, old_file_value, new_file_value, name)
      if old_file_value.is_a? Hash
        if !new_file_value.is_a? Hash
          return [ "#{name} has type #{new_file_value.class} in #{new_file.path_for_printing} and #{old_file_value.class} in #{old_file.path_for_printing}" ]
        end

        results = []
        new_file_value.each_pair do |key, value|
          new_name = name != "" ? "#{name}.#{key}" : key
          if !old_file_value.has_key?(key)
            results << "#{new_name} exists in #{new_file.path_for_printing} but not in #{old_file.path_for_printing}"
          else
            results += diff_json(old_file, new_file, old_file_value[key], new_file_value[key], new_name)
          end
        end
        old_file_value.each_key do |key|
          new_name = name != "" ? "#{name}.#{key}" : key
          if !new_file_value.has_key?(key)
            results << "#{new_name} exists in #{old_file.path_for_printing} but not in #{new_file.path_for_printing}"
          end
        end
        return results
      end

      if new_file_value.is_a? Array
        if !old_file_value.is_a? Array
          return "#{name} has type #{new_file_value.class} in #{new_file.path_for_printing} and #{old_file_value.class} in #{old_file.path_for_printing}"
        end

        results = []
        if old_file_value.length != new_file_value.length
          results << "#{name} is length #{new_file_value.length} in #{new_file.path_for_printing}, and #{old_file_value.length} in #{old_file.path_for_printing}" 
        end
        0.upto([ new_file_value.length, old_file_value.length ].min - 1) do |i|
          results += diff_json(old_file, new_file, old_file_value[i], new_file_value[i], "#{name}[#{i}]")
        end
        return results
      end

      if new_file_value != old_file_value
        return [ "#{name} is #{new_file_value.inspect} in #{new_file.path_for_printing} and #{old_file_value.inspect} in #{old_file.path_for_printing}" ]
      end

      return []
    end

    def self.diffable_leaves_from_pattern(pattern, a_root, b_root, recurse_depth)
      # Make sure everything on the server is also on the filesystem, and diff
      found_paths = Set.new
      ChefFS::FileSystem.list(a_root, pattern).each do |a|
        found_paths << a.path
        b = ChefFS::FileSystem.get_path(b_root, a.path)
        diffable_leaves(a, b, recurse_depth) do |a_leaf, b_leaf|
          yield [ a_leaf, b_leaf ]
        end
      end

      # Check the outer regex pattern to see if it matches anything on the filesystem that isn't on the server
      ChefFS::FileSystem.list(b_root, pattern).each do |b|
        if !found_paths.include?(b.path)
          a = ChefFS::FileSystem.get_path(a_root, b.path)
          yield [ a, b ]
        end
      end
    end

    def self.diffable_leaves(a, b, recurse_depth)
      # If we have children, recurse into them and diff the children instead of returning ourselves.
      if recurse_depth != 0 && a.dir? && b.dir? && a.children.length > 0 && b.children.length > 0
        a_children_names = Set.new
        a.children.each do |a_child|
          a_children_names << a_child.name
          diffable_leaves(a_child, b.child(a_child.name), recurse_depth ? recurse_depth - 1 : nil) do |a_leaf, b_leaf|
            yield [ a_leaf, b_leaf ]
          end
        end

        # Check b for children that aren't in a
        b.children.each do |b_child|
          if !a_children_names.include?(b_child.name)
            yield [ a.child(name), b_child ]
          end
        end
        return
      end

      # Otherwise, this is a leaf we must diff.
      yield [a, b]
    end

    private

    def self.read_file_value(file)
      begin
        return file.read
      rescue ChefFS::FileSystem::NotFoundException
        return nil
      end
    end
  end
end
