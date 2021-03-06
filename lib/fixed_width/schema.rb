module FixedWidth
  class Schema
    include Config::API

    options.define(
      name: { transform: :to_sym, validate: :blank },
      parent: { validate: Config::API },
      trap: { transform: :nil_or_proc }
    )
    options.configure(
      required: [:name, :parent],
      reader: [:name, :parent]
    )

    RESERVED_NAMES = /^spacer|repeat/

    def initialize(opts)
      initialize_options(opts)
      initialize_options(parent.options)
      @in_setup = false
      @spacer_count = 0
    end

    # DSL methods

    def schema(*args, &block)
      opts = validate_schema_func_args(args, block_given?)
      if block_given? # new sub-schema
        child = Schema.new(opts.merge(parent: self))
        child.setup(&block)
        save_field(child)
      else # existing schema
        save_field(opts)
      end
    end

    def column(name, length, opts={})
      col = Column.new(opts.merge(name: name, length: length, parent: self))
      save_field(col)
    end

    def spacer(length, pad=nil)
      opts = { name: :spacer, length: length}
      opts[:padding] = pad if pad
      col = Column.new(opts)
      name = :"spacer_#{@spacer_count += 1}"
      fields << name
      entries[name] = {type: 'spacer', entry: col}
      name
    end

    def trap(&block)
      set_opt(:trap, block) if block_given?
      opt(:trap)
    end

    def setup(&block)
      raiser << "already in #setup; recursion forbidden" if @in_setup
      raiser << "#setup requires a block!" unless block_given?
      @in_setup = true
      instance_eval(&block)
    ensure
      @in_setup = false
    end

    def respond_to_missing?(method, *)
      @in_setup || super
    end

    def method_missing(method, *args, &block)
      return super unless @in_setup
      return schema(method, *args, &block) if block_given?
      column(method, *args)
    rescue => e
      raise unless e.is_a?(ArgumentError)
      b = [block_given?, block.try(:source_location)]
      raiser << [method, args, b, e.inspect].inspect
    end

    # Data methods

    def length
      @length = nil if @fields_hash != fields.hash
      @length ||= begin
        @fields_hash = fields.hash
        fields.map { |f|
          lookup(f,raiser).length
        }.reduce(0,:+)
      end
    end

    def field_names
      fields.to_enum
    end

    def schemas
      return enum_for(:schemas) unless block_given?
      entry_enum('schema') { |x| yield x.last }
    end

    def columns
      return enum_for(:columns) unless block_given?
      entry_enum('column') { |x| yield x.last }
    end

    def referenced_schemas
      return enum_for(:referenced_schemas) unless block_given?
      entry_enum('referenced_schema') { |(name,schema)|
        schema = schema[:schema_name] if schema.is_a?(Hash)
        yield [name, schema]
      }
    end

    def inspect
      string = "#<#{self.class.name}:#{self.object_id}"
      string << " name=:#{name}"
      string << ", length=#{length rescue "error"}"
      string << ", schemas=#{schemas.map(&:name).inspect}"
      string << ", columns=#{columns.map(&:name).inspect}"
      refs = referenced_schemas.map{ |(n,s)|
        sn = s.is_a?(Schema) ? s.name : s
        sn == n ? ":#{n}" : "#{n}(:#{sn})"
      }
      string << ", referenced_schemas=[#{refs.join(", ")}]"
      string << ", errors=#{errors.inspect}"
      string << ">"
    end

    def valid?
      errors.empty?
    end

    def validate!
      got = errors
      if got.length > 0
        raiser << "Schema has errors: #{got.join(" ; ")}"
      end
      self
    end

    # Parsing methods

    def match(raw_line)
      raw_line.nil? ? false :
        raw_line.rstrip.length <= self.length &&
          (!trap || trap.call(raw_line))
    end

    def parse(line, start_pos = 0)
      # need to update to use groups
      data = {}
      cursor = start_pos
      fields.each do |field|
        found = lookup(field, raiser)
        case found
        when Column
          unless found.name == :spacer
            capture = line.mb_chars[cursor..cursor+found.length-1] || ''
            data[field] = found.parse(capture, self)
          end
          cursor += found.length
        when Schema
          data[field] = found.parse(line, cursor)
          cursor += found.length
        else
          raise SchemaError, field_type_error(found)
        end
      end
      data
    end

    def format(data)
      # need to update to use groups
      fields.map do |f|
        found = lookup(f, raiser)
        found.format(data[f])
      end.join
    end

    protected

    def lookup(name, err = nil)
      if found = entries[name]
        return found[:entry] if found.key?(:entry)
        if found[:type] != "referenced_schema"
          err << %{
            Entry missing for field '#{name}' of type '#{found[:type]}'
          }.squish if err
        else
          recurse_on = found[:schema_name]
        end
      else
        recurse_on = name
      end
      if recurse_on
        entry = case
        when parent.is_a?(Schema)
          parent.lookup(recurse_on)
        when parent.respond_to?(:schemas)
          parent.schemas(recurse_on).first
        end
        if entry.is_a?(Schema)
          if found
            (found[:passed_options] || []).each do |popts|
              pass_options(entry, popts)
            end
            pass_options(entry, found[:options])
            pass_options(entry, self.options)
            found[:entry] = entry
          end
          return entry
        end
        because = " ; found #{entry.inspect} instead" if entry
        err << %{
          Could not find referenced schema '#{recurse_on}' for field
          named '#{name}' in schema '#{self.name}'#{because || ""}
        }.squish if err
      end
      nil
    end

    def pass_options(schema, opts = nil)
      if found = entries[schema]
        if !found[:entry] && found[:type] == 'referenced_schema'
          found[:passed_options] ||= []
          found[:passed_options] << opts
          return schema
        end
      end
      if schema.is_a?(Schema)
        if opts.is_a?(Hash)
          opts.each do |k,v|
            to_set = ([schema] + schema.columns.to_a).map(&:options)
            to_set.each{ |t| t.set(k,v,true) }
          end
        elsif opts.is_a?(Config::Options)
          merge_ops = {prefer: :self, missing: :undefined}
          schema.options.merge!(opts, merge_ops)
          schema.columns.each do |col|
            col.options.merge!(opts, merge_ops)
          end
        else
          raiser << "Unknown option type: #{opts.inspect}"
        end
        schema.schemas.each do |s|
          schema.pass_options(s, opts)
        end
        schema.referenced_schemas.each do |(n,rs)|
          if rs.is_a?(Schema)
            schema.pass_options(rs, opts)
          else
            schema.pass_options(n, opts)
          end
        end
      else
        raiser << "Cannot pass options to `#{schema.inspect}`"
      end
      schema
    end

    def errors
      fields.reduce([]) { |errs, field|
        entry = lookup(field, errs)
        errs + case entry
        when Column, NilClass then []
        when Schema then entry.errors
        else [field_type_error(entry)]
        end
      }
    end

    private

    # Argument Handling

    def validate_schema_func_args(args, has_block)
      case args.count
      when 1
        arg = args.first
        return {name: arg.to_sym} if arg.respond_to?(:to_sym)
        if arg.is_a?(Hash)
          return arg if arg.key?(:name) || arg.key?(:schema_name)
          if !has_block && arg.count == 1
            list = [arg.keys.first, {schema_name: arg.values.first}]
            return validate_schema_func_args(list, has_block)
          end
        end
      when 2
        name, opts = args
        if name.respond_to?(:to_sym)
          if opts.is_a?(Hash)
            names = case
            when !opts.key?(:name)
              {name: name.to_sym}
            when !opts.key?(:schema_name)
              {schema_name: name.to_sym}
            else nil
            end
            return opts.merge(names) if names
          end
        end
      end
      expected = "[name, options = {}]"
      expected += " OR [{name: schema_name}]" unless has_block
      raise SchemaError.new %{
        Unexpected arguments for #schema. Expected #{expected}.
        Got #{args.inspect}#{" and a block" if has_block}
      }.squish
    end

    # Field Handling

    def fields
      @fields ||= []
    end

    def entries
      @entries ||= {}
    end

    def save_field(field)
      if field.is_a?(Hash)
        field_name, schema_name = hash_to_name_list(field)
      else
        field_name = field.name
      end
      raise SchemaError.new %{
        Field has no name: #{field.inspect}
      }.squish unless field_name
      raise SchemaError.new %{
        Invalid Name: '#{field_name}' is reserved!
      }.squish if RESERVED_NAMES =~ field_name
      if existing = entries[field_name]
        raise DuplicateNameError.new %{
          You already have a #{existing[:type]} named '#{field_name}'
        }.squish
      end
      check_schema_conflict(field) if field.is_a?(Schema)
      fields << field_name
      entries[field_name] = case field
        when Schema then {type: 'schema', entry: field}
        when Column then {type: 'column', entry: field}
        when Hash
          {   type: 'referenced_schema', schema_name: schema_name,
              options: field.reject{ |k,v| [:name, :schema_name].include?(k) }
          }
        else raise SchemaError, field_type_error(f)
      end
      field_name
    end

    def hash_to_name_list(field)
      schema_name = field[:schema_name] || field[:name]
      store_name = field[:name] || schema_name
      return nil unless store_name && schema_name
      [store_name, schema_name].map(&:to_sym)
    end

    def entry_enum(type)
      fields.each do |field|
        if entry = entries[field]
          if entry[:type] == type
            if entry[:entry]
              yield [field, entry[:entry]]
            else
              yield [field, entry]
            end
          end
        end
      end
    end

    # Exception Handling

    def check_schema_conflict(schema)
      conflict = referenced_schemas.find { |(_,s)|
        sn = s.is_a?(Schema) ? s.name : s
        sn == schema.name
      }
      raise DuplicateNameError.new %{
        An imported schema of type #{schema.name}
        conflicts with the new schema: old =
        #{conflict.inspect}, new = #{schema.inspect}
      }.squish if conflict
    end

    def field_type_error(f)
      "Unknown field type: #{f.inspect}"
    end

    def raiser
      @raiser ||= Class.new do
        def <<(msg)
          raise SchemaError, msg
        end
      end.new
    end

  end
end
