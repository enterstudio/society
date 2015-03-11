module Society

  # The Parser class is responsible for producing an ObjectGraph from one or
  # more ruby sources.
  class Parser

    # Public: Generate a list of files from a collection of paths, creating a
    # new Parser with them.
    # Note: Since the files are not read, a new Parser MAY be returned such
    # that initiating processing will cause a crash later.
    #
    # file_paths - Any number of Strings representing paths to files.
    #
    # Returns a Parser.
    def self.for_files(*file_paths)
      files = file_paths.flatten.flat_map do |path|
        File.directory?(path) ? Dir.glob(File.join(path, '**', '*.rb')) : path
      end
      new(files.lazy.map { |f| File.read(f) })
    end

    # Public: Create a Parser with a collection of ruby sources to be analyzed.
    #
    # source - Any number of Strings containing ruby source.
    #
    # Returns a Parser.
    def self.for_source(*source)
      new(source.lazy)
    end

    # Public: Create a Parser, staging ruby source files to be analyzed.
    #
    # source - An Enumerable containing ruby source strings.
    def initialize(source)
      @source = source.map { |file| graph_from(file) }
    end

    # Public: Generate a report from the object graph.
    #
    # format      - A symbol representing any known output format.
    # output_path - Path to which output should be written. (default: nil)
    #
    # Returns nothing.
    def report(format, output_path=nil)
      raise ArgumentError, "Unknown format #{format}" unless known_formats.include?(format)
      options = { json_data: graph.to_json }
      options[:output_path] = output_path unless output_path.nil?
      FORMATTERS[format].new(options).write
    end

    # Public: Return the ObjectGraph representing the analyzed source.  Calling
    # this method will trigger the analysis of the source if the object was
    # created with lazy enumerables.
    #
    # Returns an ObjectGraph.
    def graph
      @graph ||= resolve_known_edges(source.reduce(ObjectGraph.new, &:+))
    end

    # Public: Return a list of known classes from the object graph.
    #
    # Returns an Array of Strings.
    def classes
      graph.map(&:name)
    end

    private

    attr_reader :source

    # AST Node with the current namespace and type (module/class) preserved.
    NSNode = Struct.new(:namespace, :type, :ast)
    # ActiveRecord edge, containing the direct reference and any arguments.
    AREdge = Struct.new(:reference, :args)

    NAMESPACE_NODES     = [:class, :module]
    NAMESPACE_SEPARATOR = '::'
    CONSTANT_NAME_NODES = [:const_ref, :const_path_ref, :@const]
    ACTIVERECORD_NODES  = %w(belongs_to has_one has_many
                             has_and_belongs_to_many)

    # Internal: Generate an ObjectGraph from a string containing ruby source.
    #
    # source - String containing ruby source.
    #
    # Returns an ObjectGraph.
    def graph_from(source)
      ast = Ripper.sexp(source)
      nodes_from(ast).reduce(Society::ObjectGraph.new, &:<<)
    end

    # Internal: Generate a list of Nodes from a string containing ruby source.
    # Note: All edges are considered unresolved at this stage.
    #
    # ast - Array containing an abstract syntax tree generated by Ripper.
    #
    # Returns an Array of Nodes.
    def nodes_from(ast)
      walk_ast(ast).map do |name, data|
        init_node = Society::Node.new(name: name, type: data[:type])
        find_edges(name, data[:ast]).reduce(init_node) do |node, new_edge|
          edge = [Society::Edge.new(to: new_edge)]
          type = data[:type]
          Society::Node.new(name: name, type: type, unresolved: edge) + node
        end
      end
    end

    # Internal: Isolate individual namespaces, generating a hash containing
    # Namespace => AST pairs.
    #
    # ast - Array containing an abstract syntax tree generated by Ripper.
    #
    # Returns a Hash mapping Namespace => AST.
    def walk_ast(ast)
      scoped_nodes = filter_namespace([], ast)

      scoped_nodes.reduce({}) do |nodes, node|
        namespace = node[:namespace] + [node_name(node[:namespace], node[:ast])]
        filter_namespace(namespace, node[:ast]).each do |sub|
          scoped_nodes.push(sub)
        end
        nodes.merge({ namespace.last => node })
      end
    end

    # Internal: Generate a list of nodes representing a change of namespace
    # (classes/modules) from an abstract syntax tree, preserving the namespace
    # associated with them.
    #
    # namespace - Array containing the current namespace, to be preserved along
    #             with the AST.
    # ast       - AST to be searched for namespace separators.  Note that due
    #             to this object being globbed, mutating this object will not
    #             mutate the state of the object passed to this method.
    #
    # Returns an Array of NSNodes.
    def filter_namespace(namespace, *ast)
      ast.reduce([]) do |nodes, node|
        if node.is_a?(Array)
          if NAMESPACE_NODES.include?(node.first)
            nodes.push(NSNode.new(namespace, node.first, node[1..-1]))
          else
            node.each { |sub| ast.push(sub) }
          end
        end
        nodes
      end
    end

    # Internal: Determine the name of a given node which creates a new
    # namespace (module/class).
    #
    # References to constants appear in the following two forms, with the
    # indicator that a constant follows (CONSTANT_NAME_NODES) always in the
    # leftmost branch:
    #   [:const_ref, [:@const, "Klass", [1, 6]]]
    # and:
    #   [:const_path_ref,
    #     [:var_ref, [:@const, "Namespaced", [1, 6]]],
    #     [:@const, "Klass", [1, 18]]]
    #
    # namespace - Array containing the current namespace, used to determine the
    #             full namespace of the node.
    # ast       - AST to be searched for references to constants.  This object
    #             is globbed, so it may be mutated safely.
    #
    # Raises ArgumentError if no name can be found.
    # Returns a String.
    def node_name(namespace, *ast)
      ast.reduce([]) do |path, node|
        if node.is_a?(Array)
          if CONSTANT_NAME_NODES.include?(node.first)
            name = path.push(node.flatten.select { |e| e.is_a?(String) })
            return((namespace + name).flatten.join(NAMESPACE_SEPARATOR))
          end
          ast.push(node.first)
        end
        path
      end
      raise(ArgumentError, 'No constant name found in the tree.')
    end

    # Internal: Find all references to edges (defined as references to external
    # constants) within the current scope.
    #
    # parent - String containing the name of the current node.
    # ast    - AST to be searched for references to constants.
    #
    # Returns an Array of Strings and AREdges.
    def find_edges(parent, ast)
      direct_reference_edges(parent, ast) + activerecord_edges(ast)
    end

    # Internal: Find all explicit references to edges within the current scope.
    #
    # parent - String containing the name of the current node.
    # ast    - AST to be searched for references to constants.  This object is
    #          globbed, so it may be mutated safely.
    #
    # Returns an Array of Strings.
    def direct_reference_edges(parent, *ast)
      ast.reduce([]) do |edges, node|
        if node.is_a?(Array) && !NAMESPACE_NODES.include?(node.first)
          if CONSTANT_NAME_NODES.include?(node.first)
            edges.push(node)
          else
            node.each { |sub| ast.push(sub) }
          end
        end
        edges
      end.map { |node| node_name([], node) }.reject { |node| parent == node }
    end

    # Internal: Find all references to edges via ActiveRecord associations
    # (belongs_to, has_one, has_many, has_and_belongs_to_many) in the current
    # scope.
    #
    # ast - AST to be searched for references to ActiveRecord associations.
    #       This object is globbed, so it may be mutated safely.
    #
    # Returns an Array of AREdges.
    def activerecord_edges(*ast)
      activerecord_nodes(ast).reduce([]) do |edges, node|
        if node.is_a?(Array) && !NAMESPACE_NODES.include?(node.first)
          node_type, args = node
          if ACTIVERECORD_NODES.include?(node_type[1])
            edges.push(activerecord_references(args))
          end
        end
        edges
      end.compact.map { |edge| AREdge.new(edge[:reference], edge[:args]) }
    end

    # Internal: Find and return all instances of ActiveRecord association
    # nodes.
    #
    # These will match the following pattern:
    #   [:command,
    #     [:@ident, "has_many", [2, 10]],
    #     [:args_add_block,
    #       [[:symbol_literal, [:symbol, [:@ident, "associations", [2, 22]]]],
    #         [:bare_assoc_hash,
    #           [[:assoc_new,
    #             [:@label, "polymorphic:", [2, 33]],
    #             [:var_ref, [:@kw, "true", [2, 46]]]]]]], false]]
    # Note: the bare_assoc_hash node is optional and only appears in cases
    # where additional arguments beyond the association name are passed.
    #
    # ast - AST to be searched for references to ActiveRecord associations.
    #
    # Returns an Array of AST nodes.
    def activerecord_nodes(ast)
      ast.reduce([]) do |nodes, node|
        if node.is_a?(Array) && !NAMESPACE_NODES.include?(node.first)
          if [:command].include?(node.first)
            if ACTIVERECORD_NODES.include?(node[1][1])
              nodes.push(node[1..-1])
            end
          else
            node.each { |sub| ast.push(sub) }
          end
        end
        nodes
      end
    end

    # Internal: Process argument blocks (args_add_block nodes), returning a
    # Hash representative of the arguments passed to a given ActiveRecord
    # association command.
    #
    # The block will match the following pattern:
    #   [:args_add_block,
    #     [[:symbol_literal, [:symbol, [:@ident, "associations", [2, 22]]]],
    #       [:bare_assoc_hash,
    #         [[:assoc_new,
    #           [:@label, "polymorphic:", [2, 33]],
    #           [:var_ref, [:@kw, "true", [2, 46]]]]]]], false]
    # Note: the bare_assoc_hash node is optional and only appears in cases
    # where additional arguments beyond the association name are passed.
    #
    # args - AST representing an arguments block to be processed.
    #
    # Returns a Hash or nil.
    def activerecord_references(args)
      return nil unless args.is_a?(Array) && args.first == :args_add_block
      arg_tree = args[1]
      arg_tree.reduce({}) do |references, node|
        if node.is_a?(Array) && !NAMESPACE_NODES.include?(node.first)
          references.merge(process_reference_ast(node))
        else
          references
        end
      end
    end

    # Internal: Process argument blocks (args_add_block nodes), returning a
    # Hash representative of one of the arguments passed to a given
    # ActiveRecord association command.
    #
    # The block will match the following patterns:
    #   [:symbol_literal, [:symbol, [:@ident, "associations", [2, 22]]]]
    # or:
    #   [:bare_assoc_hash,
    #     [[:assoc_new,
    #       [:@label, "polymorphic:", [2, 33]],
    #       [:var_ref, [:@kw, "true", [2, 46]]]]]]
    # Note: the bare_assoc_hash node is optional and only appears in cases
    # where additional arguments beyond the association name are passed.
    #
    # node - AST representing an argument block to be processed.
    #
    # Returns a Hash.
    def process_reference_ast(node)
      if [:symbol_literal].include?(node.first)
        { reference: node.flatten.detect { |e| e.is_a?(String) } }
      elsif [:bare_assoc_hash].include?(node.first)
        { args: arguments_hash(node[1]) }
      else
        { }
      end
    end

    # Internal: Generate a Hash from a block describing a Hash.
    #
    # The block will match the following pattern:
    #   [[:assoc_new,
    #     [:@label, "polymorphic:", [2, 33]],
    #     [:var_ref, [:@kw, "true", [2, 46]]]]]
    #
    # node - AST representing a hash definition block to be processed.
    #
    # Returns a Hash.
    def arguments_hash(node)
      node.select { |node| node.first == :assoc_new }.reduce({}) do |hash, node|
        key, val = node[1,2].map do |node|
          if node.is_a?(Array)
            node.flatten.detect { |element| element.is_a?(String) }
          end
        end
        key && val ? hash.merge({ key.gsub(/:/, '') => val }) : hash
      end
    end

    # Internal: Attempt to resolve all edges for the nodes contained within an
    # ObjectGraph.
    #
    # graph - ObjectGraph to process.
    #
    # Returns an ObjectGraph.
    def resolve_known_edges(graph)
      resolve_known_activerecord_edges(graph) + resolve_direct_edges(graph)
    end

    # Internal: Attempt to resolve all directly referenced edges for the nodes
    # contained within an ObjectGraph, discarding all unresolved edges after
    # this step.
    #
    # graph - ObjectGraph to process.
    #
    # Returns an ObjectGraph.
    def resolve_direct_edges(graph)
      known_nodes = graph.map(&:name)
      new_graph = graph.map do |node|
        known = node.unresolved.select { |edge| known_nodes.include?(edge.to) }
        Society::Node.new(name: node.name, type: node.type, edges: known)
      end
      Society::ObjectGraph.new(new_graph)
    end

    # Internal: Attempt to resolve all ActiveRecord association edges for the
    # nodes contained within an ObjectGraph, discarding all unresolved edges
    # after this step.
    #
    # graph - ObjectGraph to process.
    #
    # Returns an ObjectGraph.
    def resolve_known_activerecord_edges(graph)
      aredges = graph.map do |node|
        node.unresolved.select { |edge| edge.to.is_a?(AREdge) }
          .map(&:to).each_with_object(node).to_a.map(&:reverse)
      end.flatten(1)
      argraph = aredges.reduce(graph) do |graph, edge_tuple|
        node, edge = edge_tuple
        graph << add_meta_to_node(node, edge[:args], edge[:reference])
      end
      graph + argraph.map { |n| resolve_activerecord_associations(argraph, n) }
    end

    # Internal: Generate a Node with metainformation populated from
    # ActiveRecord association information.
    #
    # node      - Node object to which the arglist should be added as meta
    #             information.
    # args_hash - Hash containing arguments passed to the ActiveRecord
    #             association if any; nil otherwise.
    # ref       - Reference for the ActiveRecord association.
    #
    # Returns a Node.
    def add_meta_to_node(node, args_hash, ref)
      refs = ({ reference: ref }).merge(args_hash || {})
      node + Node.new(name: node.name, type: node.type, meta: [refs])
    end

    # Internal: Generate a Node with edges resolved by searching the graph for
    # nodes with corresponding ActiveRecord associations (e.g. as: relations
    # for polymorphic ActiveRecord associations.)
    #
    # graph - ObjectGraph containing nodes to search for associations.
    # node  - Node object for which ActiveRecord associations will be resolved.
    #
    # Returns a Node.
    def resolve_activerecord_associations(graph, node)
      return node if node.meta.empty?
      init_data = { name: node.name, type: node.type }

      node.meta.reduce(Society::Node.new(init_data)) do |node, meta|
        edges = edge_names_from_meta_node(graph, meta).map do |edge_name|
          Society::Edge.new(to: edge_name)
        end
        node + Society::Node.new(init_data.merge({ edges: edges }))
      end
    end

    # Internal: Determine all edges for a given ActiveRecord association based
    # on a search of a global graph for corresponding associations (e.g. as:
    # for polymorphic associations.)
    # Only one type of association will be resolved for any given set of
    # meta-information; the ActiveRecord reference itself is used as a
    # fallback.
    #
    # graph - ObjectGraph containing nodes to search for associations.
    # meta  - Hash containing meta information to use in resolving the
    #         association.
    #
    # Returns an Array of Strings.
    def edge_names_from_meta_node(graph, meta)
      edge = meta['class_name'] ||
        process_through_meta_node(graph, meta) ||
        process_polymorphic_meta_node(graph, meta) ||
        meta[:reference]

      [edge].flatten.map(&:pluralize).map(&:classify)
    end

    # Internal: Resolve references for 'through' ActiveRecord associations.
    #
    # graph - ObjectGraph containing nodes to search for associations.
    # meta  - Hash containing meta information to use in resolving the
    #         association.
    #
    # Returns an Array of Strings.
    def process_through_meta_node(graph, meta)
      return nil unless meta['through']

      through = meta['through'].pluralize.classify
      ref     = meta['source'] || meta[:reference]
      graph.select { |n| n.name == through }.flat_map do |n|
        n.meta.select { |m| [ref, ref.singularize].include?(m[:reference]) }
      end.map { |meta| edge_names_from_meta_node(graph, meta) }
    end

    # Internal: Resolve references for polymorphic ActiveRecord associations.
    #
    # graph - ObjectGraph containing nodes to search for associations.
    # meta  - Hash containing meta information to use in resolving the
    #         association.
    #
    # Returns an Array of Strings.
    def process_polymorphic_meta_node(graph, meta)
      return nil unless meta['polymorphic']
      graph.select do |n|
        n.meta.select { |m| m['as'] == meta[:reference] }.any?
      end.map(&:name)
    end

    FORMATTERS = {
      html: Society::Formatter::Report::HTML,
      json: Society::Formatter::Report::Json
    }

    # Internal: List known output formatters.
    #
    # Returns an Array of Symbols.
    def known_formats
      FORMATTERS.keys
    end

  end

end

