require "file_utils"
require "../spec"
require "../dependency"
require "../errors"
require "../script"

module Shards
  abstract class Resolver
    getter name : String
    getter source : String

    def initialize(@name : String, @source : String)
    end

    def self.build(key : String, name : String, source : String)
      _, source = self.normalize_key_source(key, source)
      self.new(name, source)
    end

    def self.normalize_key_source(key : String, source : String)
      {key, source}
    end

    def ==(other : Resolver)
      return true if super
      return false unless self.class == other.class
      name == other.name && source == other.source
    end

    def yaml_source_entry
      "#{self.class.key}: #{source}"
    end

    def installed_spec
      return unless installed?

      path = File.join(install_path, SPEC_FILENAME)
      if installed = Shards.info.installed[name]?
        version = installed.requirement.as?(Version)
      end

      unless File.exists?(path)
        if version
          return Spec.new(name, version)
        else
          raise Error.new("Missing #{SPEC_FILENAME.inspect} for #{name.inspect}")
        end
      end

      begin
        spec = Spec.from_file(path)
        spec.version = version if version
        spec
      rescue error : ParseError
        error.resolver = self
        raise error
      end
    end

    def installed?
      File.exists?(install_path) && Shards.info.installed.has_key?(name)
    end

    def versions_for(req : Requirement) : Array(Version)
      case req
      when Version then [req]
      when Ref
        [latest_version_for_ref(req)]
      when VersionReq
        Versions.resolve(available_releases, req)
      when Any
        releases = available_releases
        if releases.empty?
          [latest_version_for_ref(nil)]
        else
          releases
        end
      else
        raise Error.new("Unexpected requirement type: #{req}")
      end
    end

    abstract def available_releases : Array(Version)

    def latest_version_for_ref(ref : Ref?) : Version
      raise "Unsupported ref type for this resolver: #{ref}"
    end

    def matches_ref?(ref : Ref, version : Version)
      false
    end

    def spec(version : Version) : Spec
      if spec = load_spec(version)
        spec.version = version
        spec
      else
        Spec.new(name, version, self)
      end
    end

    private def load_spec(version)
      if spec_yaml = read_spec(version)
        Spec.from_yaml(spec_yaml).tap do |spec|
          spec.resolver = self
        end
      end
    rescue error : ParseError
      error.resolver = self
      raise error
    end

    abstract def read_spec(version : Version) : String?
    abstract def install_sources(version : Version)
    abstract def report_version(version : Version) : String

    def install(version : Version)
      cleanup_install_directory

      install_sources(version)
      Shards.info.installed[name] = Dependency.new(name, self, version)
      Shards.info.save
    end

    def run_script(name)
      if installed? && (command = installed_spec.try(&.scripts[name]?))
        Log.info { "#{name.capitalize} of #{self.name}: #{command}" }
        Script.run(install_path, command, name, self.name)
      end
    end

    def install_path
      File.join(Shards.install_path, name)
    end

    protected def cleanup_install_directory
      Log.debug { "rm -rf '#{Helpers::Path.escape(install_path)}'" }
      FileUtils.rm_rf(install_path)
    end

    def parse_requirement(params : Hash(String, String)) : Requirement
      if version = params["version"]?
        VersionReq.new version
      else
        Any
      end
    end

    # abstract def write_requirement(req : Requirement, yaml : YAML::Builder)

    private record ResolverCacheKey, key : String, name : String, source : String
    private RESOLVER_CLASSES = {} of String => Resolver.class
    private RESOLVER_CACHE   = {} of ResolverCacheKey => Resolver

    def self.register_resolver(key, resolver)
      RESOLVER_CLASSES[key] = resolver
    end

    def self.clear_resolver_cache
      RESOLVER_CACHE.clear
    end

    def self.find_class(key : String) : Resolver.class | Nil
      RESOLVER_CLASSES[key]?
    end

    def self.find_resolver(key : String, name : String, source : String)
      resolver_class =
        if self == Resolver
          RESOLVER_CLASSES[key]? ||
            raise Error.new("Failed can't resolve dependency #{name} (unsupported resolver)")
        else
          self
        end

      key, source = resolver_class.normalize_key_source(key, source)

      RESOLVER_CACHE[ResolverCacheKey.new(key, name, source)] ||= begin
        resolver_class.build(key, name, source)
      end
    end
  end
end

require "./*"
