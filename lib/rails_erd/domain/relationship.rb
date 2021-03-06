require "set"
require "active_support/core_ext/module/delegation"
require "rails_erd/domain/relationship/cardinality"

module RailsERD
  class Domain
    # Describes a relationship between two entities. A relationship is detected
    # based on Active Record associations. One relationship may represent more
    # than one association, however. Related associations are grouped together.
    # Associations are related if they share the same foreign key, or the same
    # join table in the case of many-to-many associations.
    class Relationship
      N = Cardinality::N
    
      class << self
        def from_associations(domain, associations) # @private :nodoc:
          assoc_groups = associations.group_by { |assoc| association_identity(assoc) }
          assoc_groups.collect { |_, assoc_group| Relationship.new(domain, assoc_group.to_a) }
        end
      
        private
      
        def association_identity(assoc)
          identifier = assoc.options[:join_table] || assoc.primary_key_name.to_s
          Set[identifier, assoc.active_record, assoc.klass]
        end
      end
      
      extend Inspectable
      inspect_with :source, :destination

      # The domain in which this relationship is defined.
      attr_reader :domain

      # The source entity. It corresponds to the model that has defined a
      # +has_one+ or +has_many+ association with the other model.
      attr_reader :source
    
      # The destination entity. It corresponds to the model that has defined
      # a +belongs_to+ association with the other model.
      attr_reader :destination
    
      delegate :one_to_one?, :one_to_many?, :many_to_many?, :source_optional?,
        :destination_optional?, :to => :cardinality
  
      def initialize(domain, associations) # @private :nodoc:
        @domain = domain
        @reverse_associations, @forward_associations = *unless any_habtm?(associations)
          associations.partition(&:belongs_to?)
        else
          # Many-to-many associations don't have a clearly defined direction.
          # We sort by name and use the first model as the source.
          source = associations.first.active_record
          associations.partition { |association| association.active_record == source }
        end
      
        assoc = @forward_associations.first || @reverse_associations.first
        @source, @destination = @domain.entity_for(assoc.active_record), @domain.entity_for(assoc.klass)
        @source, @destination = @destination, @source if assoc.belongs_to?
      end
    
      # Returns all Active Record association objects that describe this
      # relationship.
      def associations
        @forward_associations + @reverse_associations
      end
    
      # Returns the cardinality of this relationship.
      def cardinality
        @cardinality ||= begin
          reverse_max = any_habtm?(associations) ? N : 1
          forward_range = associations_range(@source.model, @forward_associations, N)
          reverse_range = associations_range(@destination.model, @reverse_associations, reverse_max)
          Cardinality.new(reverse_range, forward_range)
        end
      end
    
      # Indicates if a relationship is indirect, that is, if it is defined
      # through other relationships. Indirect relationships are created in
      # Rails with <tt>has_many :through</tt> or <tt>has_one :through</tt>
      # association macros.
      def indirect?
        !@forward_associations.empty? and @forward_associations.all?(&:through_reflection)
      end
    
      # Indicates whether or not the relationship is defined by two inverse
      # associations (e.g. a +has_many+ and a corresponding +belongs_to+
      # association).
      def mutual?
        @forward_associations.any? and @reverse_associations.any?
      end
    
      # Indicates whether or not this relationship connects an entity with itself.
      def recursive?
        @source == @destination
      end
      
      # Indicated whether or not this relationship is connected to a specialized
      # entity.
      def specialized?
        source.specialized? or destination.specialized?
      end
    
      # Indicates whether the destination cardinality class of this relationship
      # is equal to one. This is +true+ for one-to-one relationships only.
      def to_one?
        cardinality.cardinality_class[1] == 1
      end
    
      # Indicates whether the destination cardinality class of this relationship
      # is equal to infinity. This is +true+ for one-to-many or
      # many-to-many relationships only.
      def to_many?
        cardinality.cardinality_class[1] != 1
      end
    
      # Indicates whether the source cardinality class of this relationship
      # is equal to one. This is +true+ for one-to-one or
      # one-to-many relationships only.
      def one_to?
        cardinality.cardinality_class[0] == 1
      end
    
      # Indicates whether the source cardinality class of this relationship
      # is equal to infinity. This is +true+ for many-to-many relationships only.
      def many_to?
        cardinality.cardinality_class[0] != 1
      end
    
      # The strength of a relationship is equal to the number of associations
      # that describe it.
      def strength
        associations.size
      end

      def <=>(other) # @private :nodoc:
        (source.name <=> other.source.name).nonzero? or (destination.name <=> other.destination.name)
      end
    
      private

      def associations_range(model, associations, absolute_max)
        # The minimum of the range is the maximum value of each association
        # minimum. If there is none, it is zero by definition. The reasoning is
        # that from all associations, if only one has a required minimum, then
        # this side of the relationship has a cardinality of at least one.
        min = associations.map { |assoc| association_minimum(model, assoc) }.max || 0

        # The maximum of the range is the maximum value of each association
        # maximum. If there is none, it is equal to the absolute maximum. If
        # only one association has a high cardinality on this side, the
        # relationship itself has the same maximum cardinality.
        max = associations.map { |assoc| association_maximum(model, assoc) }.max || absolute_max

        min..max
      end
    
      def association_minimum(model, association)
        minimum = association_validators(:presence, model, association).any? ||
          foreign_key_required?(model, association) ? 1 : 0
        length_validators = association_validators(:length, model, association)
        length_validators.map { |v| v.options[:minimum] }.compact.max or minimum
      end

      def association_maximum(model, association)
        maximum = association.collection? ? N : 1      
        length_validators = association_validators(:length, model, association)
        length_validators.map { |v| v.options[:maximum] }.compact.min or maximum
      end
    
      def association_validators(kind, model, association)
        model.validators_on(association.name).select { |v| v.kind == kind }
      end
    
      def any_habtm?(associations)
        associations.any? { |association| association.macro == :has_and_belongs_to_many }
      end
    
      def foreign_key_required?(model, association)
        if association.belongs_to?
          key = model.arel_table[association.primary_key_name] and !key.column.null
        end
      end
    end
  end
end
