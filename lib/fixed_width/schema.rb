module FixedWidth
  class Section
    include Config::API

    options.define(
      name: { transform: :to_sym, validate: :blank },
      optional: { default: false, validate: [true, false] },
      singular: { default: false, validate: [true, false] },
      parent: { validate: Config::API },
      trap: { transform: :nil_or_proc }
    )
    options.configure(
      required: [:name, :parent],
      reader: [:name, :parent, :optional, :singular],
      writer: [:optional, :singular]
    )

    # protected
    def groups
      @groups ||= {}
    end

    def group(name = nil)
      groups[name] ||= Set.new
    end

    #private
    def check_duplicates(gn, name)
      gns = gn ? "'#{gn}'" : "default"
      raise FixedWidth::DuplicateNameError.new %{
        You have already defined a column named
        '#{name}' in the #{gns} group.
      }.squish if group(gn).include?(name)
      raise FixedWidth::DuplicateNameError.new %{
        You have already defined a column named #{gns};
        you cannot have a group and column of the same name.
      }.squish if group(nil).include?(gn)
      raise FixedWidth::DuplicateNameError.new %{
        You have already defined a group named '#{name}';
        you cannot have a group and column of the same name.
      }.squish if groups.key?(name)
      gn
    end


#######################################################

    RESERVED_NAMES = [:spacer].freeze

    def initialize(opts)
      initialize_options(opts)
      initialize_options(parent.options)
      @in_setup = false
    end

    def valid?
      errors.empty?
    end

    # DSL methods

    def schema(*args, &block)
      opts = validate_schema_func_args(args, block_given?)
      if block_given? # new sub-schema
        child = Schema.new(opts.merge(parent: self))
        child.setup(&block)
        lookup(child.name, child)
        fields << child
      else # existing schema
        fields << opts # do the lookup lazily
      end
    end

    def column(name, length, opts={})
      # Construct column
      col = Column.new(opts.merge(name: name, length: length, parent: self))
      # Check name
      raise ConfigError.new %{
        Invalid Name: '#{col.name}' is a reserved keyword!
      }.squish if RESERVED_NAMES.include?(col.name)
      # Check for duplicates
      gn = check_duplicates(col.group, col.name)
      # Add the new column
      fields << col
      group(gn) << col.name
      col
    end

    def spacer(length, pad=nil)
      opts = { name: :spacer, length: length, parent: self }
      opts[:padding] = pad if pad
      col = Column.new(opts)
      fields << col
      col
    end

    def trap(&block)
      set_opt(:trap, block) if block_given?
      opt(:trap)
    end

    def setup(&block)
      raise SchemaError, "already in #setup; recursion forbidden" if @in_setup
      raise SchemaError, "#setup requires a block!" unless block_given?
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
    end

    # Data methods

    def length
      @length = nil if @fields_hash != fields.hash
      @length ||= begin
        @fields_hash = fields.hash
        fields.map(&:length).reduce(0,:+)
      end
    end

    def export
      fields.enum_for(:grep, Schema)
    end

    def columns
      fields.enum_for(:grep, Column)
    end

    # Parsing methods

    def match(raw_line)
      raw_line.nil? ? false :
        raw_line.length == self.length &&
          (!trap || trap.call(raw_line))
    end

    def parse(line, start_pos = 0)
      data = {}
      cursor = start_pos
      fields.each do |f|
        case f
        when Column
          unless f.name == :spacer
            # need to update groups for recursive schema
            # store = c.group ? data[c.group] : data
            capture = line.mb_chars[cursor..cursor+f.length-1] || ''
            data[f.name] = f.parse(capture, self)
          end
          cursor += f.length
        when Schema
          data[f.name] = f.parse(line, cursor)
          cursor += f.length
        when Hash
          schema_name = f[:schema_name] || f[:name]
          schema = schema_name && lookup(schema_name)
          if schema
            store_name = f[:name] || f[:schema_name]
            data[store_name] = f.parse(line, cursor)
            cursor += schema.length
          else
            raise SchemaError, "Cannot find schema for: #{f.inspect}"
          end
        else
          raise SchemaError, "Unknown field type: #{f.inspect}"
        end
      end
      data
    end

    def format(data)
      # need to update to use groups
      fields.map do |f|
        f.format(data[f.name])
      end.join
    end

    protected

    def fields
      @fields ||= []
    end

    def errors
      fields.reduce([]) { |errs, field|
        errs + case field
        when Hash
          if schema_name = field[:schema_name] || field[:name]
            lookup(schema_name) ? [] :
              ["Cannot find schema named `#{schema_name.inspect}`"]
          else
            ["Missing schema name: #{field.inspect}"]
          end
        when Column then []
        when Schema then field.errors
        else ["Unknown field type: #{field.inspect}"]
        end
      }
    end

    def lookup(schema_name, sval = nil)
      @lookup ||= {}
      @lookup[schema_name] = nil if sval
      @lookup[schema_name] ||= case
        when sval.is_a?(Schema) then sval
        when parent.is_a?(Schema)
          pass_options(parent.lookup(schema_name))
        when parent.respond_to?(:schemas)
          pass_options(parent.schemas(schema_name).first)
        else nil
      end
    end

    private

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
            if !opts.key?(:name) || !opts.key?(:schema_name)
              names = {name: name.to_sym}
              names[:schema_name] = opts[:name] if opts.key?(:name)
              return opts.merge(names)
            end
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

    def pass_options(schema)
      if schema
        merge_ops = {prefer: :self, missing: :undefined}
        schema.columns.each do |col|
          col.options.merge!(self.options, merge_ops)
        end
      end
      schema
    end

  end
end
