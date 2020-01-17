#!/usr/bin/env ruby -Wall
# frozen_string_literal: true

require "nokogiri"
require "thor"

module Linkatron
  class LinkatronError < StandardError
  end

  class ChildNodeNotFound < LinkatronError
    attr_reader :child_xpath, :parent_xpath, :node, :value

    def initialize(parent_xpath, child_xpath, node, value)
      @parent_xpath = parent_xpath
      @child_xpath = child_xpath
      @node = node
      @value = value

      message = sprintf("parent element \"%<parent_xpath>s\" on line %<line>d with text \"%<value>s\": child element \"%<child_xpath>s\" IS REQUIRED", {
        parent_xpath: parent_xpath.xpath_with_suffix.to_s.gsub("\"", "\\\""),
        child_xpath: child_xpath.xpath_with_suffix.to_s.gsub("\"", "\\\""),
        line: node.line,
        value: value.to_s.gsub("\"", "\\\""),
      })

      super(message)
    end
  end

  class InvalidLink < LinkatronError
    attr_reader :source_xpath, :target_xpath, :node, :value

    def initialize(source_xpath, target_xpath, node, value)
      @source_xpath = source_xpath
      @target_xpath = target_xpath
      @node = node
      @value = value

      message = sprintf("source element \"%<source_xpath>s\" on line %<line>d: target element \"%<target_xpath>s\" with text \"%<value>s\" is NOT FOUND", {
        source_xpath: source_xpath.xpath_with_suffix.to_s.gsub("\"", "\\\""),
        target_xpath: target_xpath.xpath_with_suffix.to_s.gsub("\"", "\\\""),
        line: node.line,
        value: value.to_s.gsub("\"", "\\\""),
      })

      super(message)
    end
  end

  class ValueNotFound < LinkatronError
    attr_reader :xpath, :node

    def initialize(xpath, node)
      @xpath = xpath
      @node = node

      message = sprintf("element \"%<xpath>s\" on line %<line>d is REQUIRED", {
        xpath: xpath.xpath_with_suffix.to_s.gsub("\"", "\\\""),
        line: node.line,
      })

      super(message)
    end
  end

  class Node
    class Base
      def initialize(attributes = {}, &block)
        attributes.each do |method_name, value|
          self.send(:"#{method_name}=", value)
        end

        if block_given?
          case block.arity
            when 1 then block.call(self)
            else self.instance_eval(&block)
          end
        end
      end
    end

    class Assertion < Base
      attr_accessor :child, :target
    end

    class Namespace < Base
      attr_accessor :prefix, :uri
    end

    class Pattern < Base
      attr_accessor :context, :title

      def initialize(*args, &block)
        @scopes = []

        super(*args, &block)
      end

      def scope(*args, &block)
        Scope.new(*args) do |instance|
          @scopes << instance

          if block_given?
            case block.arity
              when 1 then block.call(instance)
              else instance.instance_eval(&block)
            end
          end
        end
      end

      def validate(document, **namespaces)
        document.xpath(self.context, **namespaces).collect { |node|
          @scopes.collect { |instance|
            instance.validate(node, context, **namespaces)
          }.flatten(1)
        }.flatten(1)
      end
    end

    class Rule < Base
      attr_accessor :direction, :required, :source

      def initialize(*args, &block)
        @assertions = []

        super(*args, &block)
      end

      def assert(*args, &block)
        Assertion.new(*args) do |instance|
          @assertions << instance

          if block_given?
            case block.arity
              when 1 then block.call(instance)
              else instance.instance_eval(&block)
            end
          end
        end
      end

      def validate(node, context, **namespaces)
        new_source = Linkatron::XPath.new(self.source, **namespaces)

        new_targets = @assertions.inject({}) { |acc, instance|
          acc[Linkatron::XPath.new(instance.child, **namespaces)] = Linkatron::XPath.new(instance.target, **namespaces)
          acc
        }

        validator = Linkatron::Validator.new(new_source, new_targets, direction: self.direction, required: self.required)

        validator.validate(node, context)
      end
    end

    class Schema < Base
      attr_accessor :title

      def initialize(*args, &block)
        @namespaces = []
        @patterns = []

        super(*args, &block)
      end

      def ns(*args, &block)
        Namespace.new(*args) do |instance|
          @namespaces << instance

          if block_given?
            case block.arity
              when 1 then block.call(instance)
              else instance.instance_eval(&block)
            end
          end
        end
      end

      def pattern(*args, &block)
        Pattern.new(*args) do |instance|
          @patterns << instance

          if block_given?
            case block.arity
              when 1 then block.call(instance)
              else instance.instance_eval(&block)
            end
          end
        end
      end

      def validate(document)
        namespaces = @namespaces.inject({}) { |acc, instance|
          acc[instance.prefix.to_sym] = instance.uri.to_s
          acc
        }

        @patterns.collect { |instance|
          instance.validate(document, **namespaces)
        }.flatten(1)
      end
    end

    class Scope < Base
      attr_accessor :context

      def initialize(*args, &block)
        @rules = []
        @scopes = []

        super(*args, &block)
      end

      def rule(*args, &block)
        Rule.new(*args) do |instance|
          @rules << instance

          if block_given?
            case block.arity
              when 1 then block.call(instance)
              else instance.instance_eval(&block)
            end
          end
        end
      end

      def scope(*args, &block)
        Scope.new(*args) do |instance|
          @scopes << instance

          if block_given?
            case block.arity
              when 1 then block.call(instance)
              else instance.instance_eval(&block)
            end
          end
        end
      end

      def validate(node, context, **namespaces)
        new_context = \
          case context
          when Linkatron::XPath
            context / Linkatron::XPath.new(self.context, **namespaces)
          else
            Linkatron::XPath.new("#{context}/#{self.context}", **namespaces)
          end

        @scopes.collect { |instance|
          instance.validate(node, new_context, **namespaces)
        }.flatten(1) +
        new_context.search(node).collect { |other_node|
          @rules.collect { |instance|
            instance.validate(other_node, new_context, **namespaces)
          }.flatten(1)
        }.flatten(1)
      end
    end
  end

  class Validator
    attr_reader :source, :targets, :options

    def initialize(source, targets, **options)
      super()

      @source = source
      @targets = targets
      @options = options.dup
    end

    def validate(node, prefix = nil)
      children = self.targets.keys

      direction = (self.options[:direction] || :forward).to_sym
      required_direction_or_nil = self.options[:required].nil? ? nil : self.options[:required].to_sym

      errors = []

      with_prefix = Proc.new { |xpath|
        if prefix.nil?
          xpath
        else
          prefix / xpath
        end
      }

      if %i(forward both).include?(direction)
        self.source.search(node).each do |source_node|
          unless (value_for_source_node = self.source.value_for(source_node)).nil?
            any = false
            is_parent = false

            self.targets.each do |child, target|
              child.search(source_node).each do |child_node|
                unless (value_for_child_node = child.value_for(child_node)).nil?
                  is_parent = true

                  target_nodes = target.search(node).select { |target_node|
                    unless (value_for_target_node = target.value_for(target_node)).nil?
                      value_for_target_node == value_for_child_node
                    else
                      errors << Linkatron::ValueNotFound.new(with_prefix.call(target), target_node)

                      false
                    end
                  }

                  if target_nodes.any?
                    any = true
                  else
                    errors << Linkatron::InvalidLink.new(with_prefix.call(self.source / child), with_prefix.call(target), child_node, value_for_child_node)
                  end
                else
                  errors << Linkatron::ValueNotFound.new(with_prefix.call(self.source / child), child_node)
                end
              end
            end

            if is_parent
              if !any && %i(forward both).include?(required_direction_or_nil)
                targets.each do |child, target|
                  errors << Linkatron::InvalidLink.new(with_prefix.call(self.source / child), with_prefix.call(target), source_node, value_for_source_node)
                end
              end
            else
              if %i(forward both).include?(required_direction_or_nil)
                targets.each do |child, _target|
                  errors << Linkatron::ChildNodeNotFound.new(with_prefix.call(self.source), with_prefix.call(self.source / child), source_node, value_for_source_node)
                end
              end
            end
          else
            errors << Linkatron::ValueNotFound.new(with_prefix.call(self.source), source_node)
          end
        end
      end

      if %i(backward both).include?(direction)
        self.targets.each do |_child, target|
          target.search(node).each do |target_node|
            unless (value_for_target_node = target.value_for(target_node)).nil?
              any = false

              children.each do |child|
                self.source.search(node).each do |source_node|
                  unless (value_for_source_node = self.source.value_for(source_node)).nil?
                    child_nodes = child.search(source_node).select { |child_node|
                      unless (value_for_child_node = child.value_for(child_node)).nil?
                        value_for_child_node == value_for_target_node
                      else
                        errors << Linkatron::ValueNotFound.new(with_prefix.call(self.source / child), child_node)

                        false
                      end
                    }

                    if child_nodes.any?
                      any = true
                    end
                  else
                    errors << Linkatron::ValueNotFound.new(with_prefix.call(self.source), source_node)
                  end
                end
              end

              if !any && !required_direction_or_nil.nil? && %i(backward both).include?(required_direction_or_nil)
                children.each do |child|
                  errors << Linkatron::InvalidLink.new(with_prefix.call(target), with_prefix.call(self.source / child), target_node, value_for_target_node)
                end
              end
            else
              errors << Linkatron::ValueNotFound.new(with_prefix.call(target), target_node)
            end
          end
        end
      end

      return errors
    end
  end

  class XPath
    REGEXP_FOR_TEXT = Regexp.new("^(.*)#{Regexp.quote("/text()")}$").freeze

    REGEXP_FOR_ATTR = Regexp.new("^(.*)#{Regexp.quote("/")}#{Regexp.quote("@")}([^#{Regexp.quote("/")}]+)#{Regexp.quote("/text()")}$").freeze

    attr_reader :xpath, :namespaces

    def initialize(xpath, **namespaces)
      @xpath = xpath
      @namespaces = namespaces
    end

    def /(other)
      new_xpath = "#{self.xpath_without_suffix}/#{other.xpath_with_suffix}"
      new_namespaces = self.namespaces.merge(other.namespaces)
      other.class.new(new_xpath, **new_namespaces)
    end

    def search(node)
      node.xpath(self.xpath_without_suffix, **self.namespaces)
    end

    def value_for(node)
      if !(md = REGEXP_FOR_ATTR.match(self.xpath)).nil?
        unless (attribute = node.attribute(md[2])).nil? || (s = attribute.value.to_s.strip).empty?
          s
        else
          nil
        end
      elsif !(md = REGEXP_FOR_TEXT.match(self.xpath)).nil?
        unless !node.children.all?(&:text?) || (s = node.text.to_s.strip).empty?
          s
        else
          nil
        end
      else
        nil
      end
    end

    def xpath_without_suffix
      [REGEXP_FOR_ATTR, REGEXP_FOR_TEXT].collect { |regexp| regexp.match(self.xpath) }.reject(&:nil?).collect { |md| md[1] }.first
    end

    def xpath_with_suffix
      self.xpath
    end
  end
end

SCHEMA = Linkatron::Node::Schema.new(title: "Audit Template") do
  ns(prefix: "auc", uri: "http://buildingsync.net/schemas/bedes-auc/2019")
  pattern(title: "New York City Energy Efficiency Report", context: "/auc:BuildingSync") do
    scope(context: "auc:Facilities/auc:Facility/@ID/text()") do
      rule(source: "auc:Measures/auc:Measure/@ID/text()", required: "forward") do
        assert(child: "auc:LinkedPremises/auc:Building/auc:LinkedBuildingID/@IDref/text()", target: "auc:Sites/auc:Site/auc:Buildings/auc:Building/@ID/text()")
        assert(child: "auc:LinkedPremises/auc:Site/auc:LinkedSiteID/@IDref/text()", target: "auc:Sites/auc:Site[count(auc:Buildings/auc:Building) >= 1]/@ID/text()")
      end
      rule(source: "auc:Reports/auc:Report/@ID/text()") do
        assert(child: "auc:AuditorContactID/@IDref/text()", target: "auc:Contacts/auc:Contact/@ID/text()")
      end
      rule(source: "auc:Reports/auc:Report/@ID/text()", required: "forward") do
        assert(child: "auc:LinkedPremisesOrSystem/auc:Building/auc:LinkedBuildingID/@IDref/text()", target: "auc:Sites/auc:Site/auc:Buildings/auc:Building/@ID/text()")
        assert(child: "auc:LinkedPremisesOrSystem/auc:Site/auc:LinkedSiteID/@IDref/text()", target: "auc:Sites/auc:Site[count(auc:Buildings/auc:Building) >= 1]/@ID/text()")
      end
      rule(source: "auc:Reports/auc:Report/auc:Qualifications/auc:Qualification/@ID/text()", required: "forward") do
        assert(child: "auc:CertifiedAuditTeamMemberContactID/@IDref/text()", target: "auc:Contacts/auc:Contact/@ID/text()")
      end
      rule(source: "auc:Reports/auc:Report/auc:Scenarios/auc:Scenario/@ID/text()", required: "forward") do
        assert(child: "auc:LinkedPremises/auc:Building/auc:LinkedBuildingID/@IDref/text()", target: "auc:Sites/auc:Site/auc:Buildings/auc:Building/@ID/text()")
        assert(child: "auc:LinkedPremises/auc:Site/auc:LinkedSiteID/@IDref/text()", target: "auc:Sites/auc:Site[count(auc:Buildings/auc:Building) >= 1]/@ID/text()")
      end
      rule(source: "auc:Reports/auc:Report/auc:Scenarios/auc:Scenario/@ID/text()") do
        assert(child: "auc:UserDefinedFields/auc:UserDefinedField[auc:FieldName/text() = 'Shared Resource System ID']/auc:FieldValue/text()", target: "auc:Systems/*/*/@ID/text()")
      end
      rule(source: "auc:Reports/auc:Report/auc:Scenarios/auc:Scenario/auc:AllResourceTotals/auc:AllResourceTotal/@ID/text()") do
        assert(child: "auc:UserDefinedFields/auc:UserDefinedField[auc:FieldName/text() = 'Shared Resource System ID']/auc:FieldValue/text()", target: "auc:Systems/*/*/@ID/text()")
      end
      rule(source: "auc:Reports/auc:Report/auc:Scenarios/auc:Scenario/auc:ScenarioType/auc:PackageOfMeasures/@ID/text()") do
        assert(child: "auc:MeasureIDs/auc:MeasureID/@IDref/text()", target: "auc:Measures/auc:Measure/@ID/text()")
      end
      rule(source: "auc:Sites/auc:Site/auc:Buildings/auc:Building/auc:Sections/auc:Section[auc:SectionType/text() = 'Space function']/auc:ThermalZones/auc:ThermalZone/@ID/text()") do
        assert(child: "auc:HVACScheduleIDs/auc:HVACScheduleID/@IDref/text()", target: "auc:Schedules/auc:Schedule/@ID/text()")
      end
      rule(source: "auc:Sites/auc:Site/auc:Buildings/auc:Building/auc:Sections/auc:Section[auc:SectionType/text() = 'Whole building']/@ID/text()", direction: "both", required: "backward") do
        assert(child: "auc:ExteriorFloors/auc:ExteriorFloor/auc:ExteriorFloorID/@IDref/text()", target: "auc:Systems/auc:ExteriorFloorSystems/auc:ExteriorFloorSystem/@ID/text()")
      end
      rule(source: "auc:Sites/auc:Site/auc:Buildings/auc:Building/auc:Sections/auc:Section[auc:SectionType/text() = 'Whole building']/@ID/text()", direction: "both", required: "backward") do
        assert(child: "auc:Roofs/auc:Roof/auc:RoofID/auc:SkylightIDs/auc:SkylightID/@IDref/text()", target: "auc:Systems/auc:FenestrationSystems/auc:FenestrationSystem[auc:FenestrationType/auc:Skylight]/@ID/text()")
      end
      rule(source: "auc:Sites/auc:Site/auc:Buildings/auc:Building/auc:Sections/auc:Section[auc:SectionType/text() = 'Whole building']/@ID/text()", direction: "both", required: "backward") do
        assert(child: "auc:Sides/auc:Side/auc:DoorID/@IDref/text()", target: "auc:Systems/auc:FenestrationSystems/auc:FenestrationSystem[auc:FenestrationType/auc:Door]/@ID/text()")
      end
      rule(source: "auc:Sites/auc:Site/auc:Buildings/auc:Building/auc:Sections/auc:Section[auc:SectionType/text() = 'Whole building']/@ID/text()", direction: "both", required: "backward") do
        assert(child: "auc:Sides/auc:Side/auc:WindowID/@IDref/text()", target: "auc:Systems/auc:FenestrationSystems/auc:FenestrationSystem[auc:FenestrationType/auc:Window]/@ID/text()")
      end
      rule(source: "auc:Sites/auc:Site/auc:Buildings/auc:Building/auc:Sections/auc:Section[auc:SectionType/text() = 'Whole building']/@ID/text()", direction: "both", required: "backward") do
        assert(child: "auc:Foundations/auc:Foundation/auc:FoundationID/@IDref/text()", target: "auc:Systems/auc:FoundationSystems/auc:FoundationSystem/@ID/text()")
      end
      rule(source: "auc:Sites/auc:Site/auc:Buildings/auc:Building/auc:Sections/auc:Section[auc:SectionType/text() = 'Whole building']/@ID/text()", direction: "both", required: "backward") do
        assert(child: "auc:Roofs/auc:Roof/auc:RoofID/@IDref/text()", target: "auc:Systems/auc:RoofSystems/auc:RoofSystem/@ID/text()")
      end
      rule(source: "auc:Sites/auc:Site/auc:Buildings/auc:Building/auc:Sections/auc:Section[auc:SectionType/text() = 'Whole building']/@ID/text()", direction: "both", required: "backward") do
        assert(child: "auc:Sides/auc:Side/auc:WallID/@IDref/text()", target: "auc:Systems/auc:WallSystems/auc:WallSystem/@ID/text()")
      end
      rule(source: "auc:Systems/auc:AirInfiltrationSystems/auc:AirInfiltrationSystem/@ID/text()", required: "forward") do
        assert(child: "auc:LinkedPremises/auc:Building/auc:LinkedBuildingID/@IDref/text()", target: "auc:Sites/auc:Site/auc:Buildings/auc:Building/@ID/text()")
      end
      rule(source: "auc:Systems/auc:ConveyanceSystems/auc:ConveyanceSystem/@ID/text()", required: "forward") do
        assert(child: "auc:LinkedPremises/auc:Building/auc:LinkedBuildingID/@IDref/text()", target: "auc:Sites/auc:Site/auc:Buildings/auc:Building/@ID/text()")
      end
      rule(source: "auc:Systems/auc:ConveyanceSystems/auc:ConveyanceSystem/@ID/text()") do
        assert(child: "auc:LinkedPremises/auc:Section/auc:LinkedSectionID/@IDref/text()", target: "auc:Sites/auc:Site/auc:Buildings/auc:Building/auc:Sections/auc:Section[auc:SectionType/text() = 'Space function']/@ID/text()")
      end
      rule(source: "auc:Systems/auc:CriticalITSystems/auc:CriticalITSystem/@ID/text()", required: "forward") do
        assert(child: "auc:LinkedPremises/auc:Building/auc:LinkedBuildingID/@IDref/text()", target: "auc:Sites/auc:Site/auc:Buildings/auc:Building/@ID/text()")
      end
      rule(source: "auc:Systems/auc:DomesticHotWaterSystems/auc:DomesticHotWaterSystem/@ID/text()", required: "forward") do
        assert(child: "auc:LinkedPremises/auc:Building/auc:LinkedBuildingID/@IDref/text()", target: "auc:Sites/auc:Site/auc:Buildings/auc:Building/@ID/text()")
      end
      rule(source: "auc:Systems/auc:DomesticHotWaterSystems/auc:DomesticHotWaterSystem[auc:DomesticHotWaterType/auc:StorageTank/auc:TankHeatingType/auc:Indirect/auc:IndirectTankHeatingSource/auc:SpaceHeatingSystem]/@ID/text()", required: "forward") do
        assert(child: "auc:DomesticHotWaterType/auc:StorageTank/auc:TankHeatingType/auc:Indirect/auc:IndirectTankHeatingSource/auc:SpaceHeatingSystem/auc:HeatingPlantID/@IDref/text()", target: "auc:Systems/auc:HVACSystems/auc:HVACSystem/auc:Plants/auc:HeatingPlants/auc:HeatingPlant/@ID/text()")
      end
      rule(source: "auc:Systems/auc:FanSystems/auc:FanSystem/@ID/text()", required: "forward") do
        assert(child: "auc:LinkedSystemIDs/auc:LinkedSystemID/@IDref/text()", target: "auc:Systems/auc:HVACSystems/auc:HVACSystem/@ID/text()")
      end
      rule(source: "auc:Systems/auc:FoundationSystems/auc:FoundationSystem/@ID/text()") do
        assert(child: "auc:UserDefinedFields/auc:UserDefinedField[auc:FieldName/text() = 'Linked Wall ID']/auc:FieldValue/text()", target: "auc:Systems/auc:WallSystems/auc:WallSystem/@ID/text()")
      end
      rule(source: "auc:Systems/auc:HVACSystems/auc:HVACSystem/auc:HeatingAndCoolingSystems/auc:CoolingSources/auc:CoolingSource/@ID/text()") do
        assert(child: "auc:CoolingSourceType/auc:CoolingPlantID/@IDref/text()", target: "auc:Systems/auc:HVACSystems/auc:HVACSystem/auc:Plants/auc:CoolingPlants/auc:CoolingPlant/@ID/text()")
      end
      rule(source: "auc:Systems/auc:HVACSystems/auc:HVACSystem/auc:HeatingAndCoolingSystems/auc:Deliveries/auc:Delivery/@ID/text()") do
        assert(child: "auc:DeliveryType/auc:CentralAirDistribution/auc:ReheatPlantID/@IDref/text()", target: "auc:Systems/auc:HVACSystems/auc:HVACSystem/auc:Plants/auc:HeatingPlants/auc:HeatingPlant/@ID/text()")
      end
      rule(source: "auc:Systems/auc:HVACSystems/auc:HVACSystem/auc:HeatingAndCoolingSystems/auc:HeatingSources/auc:HeatingSource/@ID/text()") do
        assert(child: "auc:HeatingSourceType/auc:SourceHeatingPlantID/@IDref/text()", target: "auc:Systems/auc:HVACSystems/auc:HVACSystem/auc:Plants/auc:HeatingPlants/auc:HeatingPlant/@ID/text()")
      end
      rule(source: "auc:Systems/auc:HVACSystems/auc:HVACSystem/@ID/text()", required: "forward") do
        assert(child: "auc:LinkedPremises/auc:Building/auc:LinkedBuildingID/@IDref/text()", target: "auc:Sites/auc:Site/auc:Buildings/auc:Building/@ID/text()")
        assert(child: "auc:LinkedPremises/auc:Site/auc:LinkedSiteID/@IDref/text()", target: "auc:Sites/auc:Site[count(auc:Buildings/auc:Building) >= 1]/@ID/text()")
      end
      rule(source: "auc:Systems/auc:HVACSystems/auc:HVACSystem/@ID/text()") do
        assert(child: "auc:LinkedPremises/auc:Section/auc:LinkedSectionID/@IDref/text()", target: "auc:Sites/auc:Site/auc:Buildings/auc:Building/auc:Sections/auc:Section[auc:SectionType/text() = 'Space function']/@ID/text()")
      end
      rule(source: "auc:Systems/auc:HVACSystems/auc:HVACSystem/auc:Plants/auc:CondenserPlants/auc:CondenserPlant/@ID/text()") do
        assert(child: "auc:UserDefinedFields/auc:UserDefinedField[auc:FieldName/text() = 'Shared Resource Site ID']/auc:FieldValue/text()", target: "auc:Sites/auc:Site[not(auc:Buildings/auc:Building)]/@ID/text()")
      end
      rule(source: "auc:Systems/auc:HVACSystems/auc:HVACSystem/auc:Plants/auc:CoolingPlants/auc:CoolingPlant/@ID/text()") do
        assert(child: "auc:Chiller/auc:CondenserPlantIDs/auc:CondenserPlantID/@IDref/text()", target: "auc:Systems/auc:HVACSystems/auc:HVACSystem/auc:Plants/auc:CondenserPlants/auc:CondenserPlant/@ID/text()")
      end
      rule(source: "auc:Systems/auc:HVACSystems/auc:HVACSystem/auc:Plants/auc:CoolingPlants/auc:CoolingPlant/@ID/text()") do
        assert(child: "auc:UserDefinedFields/auc:UserDefinedField[auc:FieldName/text() = 'Shared Resource Site ID']/auc:FieldValue/text()", target: "auc:Sites/auc:Site[not(auc:Buildings/auc:Building)]/@ID/text()")
      end
      rule(source: "auc:Systems/auc:HVACSystems/auc:HVACSystem/auc:Plants/auc:HeatingPlants/auc:HeatingPlant/@ID/text()") do
        assert(child: "auc:UserDefinedFields/auc:UserDefinedField[auc:FieldName/text() = 'Shared Resource Site ID']/auc:FieldValue/text()", target: "auc:Sites/auc:Site[not(auc:Buildings/auc:Building)]/@ID/text()")
      end
      rule(source: "auc:Systems/auc:LightingSystems/auc:LightingSystem/@ID/text()", required: "forward") do
        assert(child: "auc:LinkedPremises/auc:Building/auc:LinkedBuildingID/@IDref/text()", target: "auc:Sites/auc:Site/auc:Buildings/auc:Building/@ID/text()")
      end
      rule(source: "auc:Systems/auc:LightingSystems/auc:LightingSystem/@ID/text()") do
        assert(child: "auc:LinkedPremises/auc:Section/auc:LinkedSectionID/@IDref/text()", target: "auc:Sites/auc:Site/auc:Buildings/auc:Building/auc:Sections/auc:Section[auc:SectionType/text() = 'Space function']/@ID/text()")
      end
      rule(source: "auc:Systems/auc:MotorSystems/auc:MotorSystem/@ID/text()", required: "forward") do
        assert(child: "auc:LinkedSystemIDs/auc:LinkedSystemID/@IDref/text()", target: "auc:Systems/auc:HVACSystems/auc:HVACSystem/@ID/text()")
      end
      rule(source: "auc:Systems/auc:OnsiteStorageTransmissionGenerationSystems/auc:OnsiteStorageTransmissionGenerationSystem/@ID/text()", required: "forward") do
        assert(child: "auc:LinkedPremises/auc:Building/auc:LinkedBuildingID/@IDref/text()", target: "auc:Sites/auc:Site/auc:Buildings/auc:Building/@ID/text()")
      end
      rule(source: "auc:Systems/auc:PlugLoads/auc:PlugLoad[auc:PlugLoadType/text() = 'Miscellaneous Electric Load']/@ID/text()", required: "forward") do
        assert(child: "auc:LinkedPremises/auc:Section/auc:LinkedSectionID/@IDref/text()", target: "auc:Sites/auc:Site/auc:Buildings/auc:Building/auc:Sections/auc:Section[auc:SectionType/text() = 'Space function']/@ID/text()")
      end
      rule(source: "auc:Systems/auc:ProcessLoads/auc:ProcessLoad[auc:ProcessLoadType/text() = 'Miscellaneous Gas Load']/@ID/text()", required: "forward") do
        assert(child: "auc:LinkedPremises/auc:Section/auc:LinkedSectionID/@IDref/text()", target: "auc:Sites/auc:Site/auc:Buildings/auc:Building/auc:Sections/auc:Section[auc:SectionType/text() = 'Space function']/@ID/text()")
      end
      rule(source: "auc:Systems/auc:PumpSystems/auc:PumpSystem/@ID/text()", required: "forward") do
        assert(child: "auc:LinkedSystemIDs/auc:LinkedSystemID/@IDref/text()", target: "auc:Systems/auc:HVACSystems/auc:HVACSystem/auc:Plants/auc:CondenserPlants/auc:CondenserPlant | auc:Systems/auc:HVACSystems/auc:HVACSystem/auc:Plants/auc:CoolingPlants/auc:CoolingPlant/@ID/text()")
      end
      scope(context: "auc:Reports/auc:Report/@ID/text()") do
        rule(source: "auc:Scenarios/auc:Scenario/auc:ResourceUses/auc:ResourceUse/@ID/text()") do
          assert(child: "auc:UtilityIDs/auc:UtilityID/@IDref/text()", target: "auc:Utilities/auc:Utility/@ID/text()")
        end
        scope(context: "auc:Scenarios/auc:Scenario/@ID/text()") do
          rule(source: "auc:AllResourceTotals/auc:AllResourceTotal/@ID/text()") do
            assert(child: "auc:UserDefinedFields/auc:UserDefinedField[auc:FieldName/text() = 'Linked Time Series ID']/auc:FieldValue/text()", target: "auc:TimeSeriesData/auc:TimeSeries/@ID/text()")
          end
          rule(source: "auc:TimeSeriesData/auc:TimeSeries/@ID/text()", required: "forward") do
            assert(child: "auc:ResourceUseID/@IDref/text()", target: "auc:ResourceUses/auc:ResourceUse/@ID/text()")
          end
        end
      end
      scope(context: "auc:Systems/auc:HVACSystems/auc:HVACSystem/@ID/text()") do
        rule(source: "auc:OtherHVACSystems/auc:OtherHVACSystem/@ID/text()") do
          assert(child: "auc:LinkedDeliveryIDs/auc:LinkedDeliveryID/@IDref/text()", target: "auc:HeatingAndCoolingSystems/auc:Deliveries/auc:Delivery/@ID/text()")
        end
        rule(source: "auc:HeatingAndCoolingSystems/auc:Deliveries/auc:Delivery/@ID/text()") do
          assert(child: "auc:CoolingSourceID/@IDref/text()", target: "auc:HeatingAndCoolingSystems/auc:CoolingSources/auc:CoolingSource/@ID/text()")
        end
        rule(source: "auc:HeatingAndCoolingSystems/auc:Deliveries/auc:Delivery/@ID/text()") do
          assert(child: "auc:HeatingSourceID/@IDref/text()", target: "auc:HeatingAndCoolingSystems/auc:HeatingSources/auc:HeatingSource/@ID/text()")
        end
      end
    end
  end
end

class CLI < Thor
  def self.exit_on_failure?
    true
  end

  desc "validate FILE", "validate \"@ID\" and \"@IDref\" links in FILE"
  def validate(filename)
    document = File.open(filename, "r") do |io|
      Nokogiri::XML(io)
    end

    if (errors = SCHEMA.validate(document)).any?
      errors.each do |error|
        $stderr.puts(error.to_s)
      end

      exit(1)
    else
      exit(0)
    end
  end
end

CLI.start(ARGV)
