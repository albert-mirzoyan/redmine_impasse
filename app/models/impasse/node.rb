module Impasse
  class Node < ActiveRecord::Base
    unloadable
    set_table_name "impasse_nodes"
    self.include_root_in_json = false

    belongs_to :parent, :class_name=>'Node', :foreign_key=> :parent_id
    has_many   :children, :class_name=> 'Node', :foreign_key=> :parent_id
    has_many   :node_keywords, :class_name => "Impasse::NodeKeyword", :dependent => :delete_all
    has_many   :keywords, :through => :node_keywords

    validates_presence_of :name

    if Rails::VERSION::MAJOR < 3 or (Rails::VERSION::MAJOR == 3 and Rails::VERSION::MINOR < 1)
      def dup
        clone
      end
    end

    def is_test_case?
      self.node_type_id == 3
    end

    def is_test_suite?
      self.node_type_id == 2
    end

    def active?
      !(attributes['active'] and attributes['active'].to_i == 0)
    end

    def planned?
      attributes['planned'].to_i == 1
    end

    def self.find_children(node_id, test_plan_id=nil, filters=nil)
      sql = <<-'END_OF_SQL'
      SELECT node.*, tc.active
      FROM (
        SELECT distinct parent.*
          FROM impasse_nodes AS parent
        LEFT JOIN impasse_nodes AS child
          ON INSTR(child.path, parent.path) > 0
        <% if conditions.include? :test_plan_id %>
        LEFT JOIN impasse_test_cases AS tc
          ON tc.id=child.id
        LEFT JOIN impasse_test_plan_cases AS tpts
          ON tc.id=tpts.test_case_id
        <% end %>
        WHERE 1=1
        <% if conditions.include? :test_plan_id %>
          AND tpts.test_plan_id=:test_plan_id
        <% end %>
        <% if conditions.include? :path %>
          AND parent.path LIKE :path
        <% end %>
        <%- if conditions.include? :filters_query or conditions.include? :filters_keywords -%>
        AND (parent.node_type_id != 3 OR (
          <%- if conditions.include? :filters_query -%>
             parent.name like :filters_query <%- if conditions.include? :filters_keywords -%>AND <%- end -%>
          <%- end -%>
          <%- if conditions.include? :filters_keywords -%>
            exists (
            SELECT 1 FROM impasse_node_keywords AS nk
              JOIN impasse_keywords AS k ON k.id = nk.keyword_id
            WHERE nk.node_id = parent.id
              AND k.keyword in (:filters_keywords))
          <%- end -%>))
        <%- end -%>
        ORDER BY LENGTH(parent.path) - LENGTH(REPLACE(parent.path,'.','')), node_order
      ) AS node
      LEFT OUTER JOIN impasse_test_cases AS tc
        ON node.id = tc.id
      WHERE 1=1
      <% unless conditions.include? :filters_inactive %>
        AND tc.active = 1 OR tc.active IS NULL
      <% end %>
      END_OF_SQL

      conditions = {}
    
      unless test_plan_id.nil?
        conditions[:test_plan_id] = test_plan_id
      end

      unless node_id.to_i == -1
        node = find(node_id)
        conditions[:path] = "#{node.path}_%"
      end
    
      if filters and filters[:query]
        conditions[:filters_query] = "%#{filters[:query]}%"
      end

      if filters and filters[:keywords]
        keywords = filters[:keywords].split(/\s*,\s*/).delete_if{|k| k == ""}.uniq
        conditions[:filters_keywords] = keywords
      end

      if filters and filters[:inactive]
        conditions[:filters_inactive] = true
      end

      find_by_sql([ERB.new(sql, nil, '-').result(binding), conditions])
    end

    def all_decendant_cases
      sql = <<-'END_OF_SQL'
      SELECT distinct parent.*
        FROM impasse_nodes AS parent
      LEFT JOIN impasse_nodes AS child
        ON INSTR(child.path, parent.path) > 0
      LEFT JOIN impasse_test_cases AS tc
        ON child.id = tc.id
      WHERE parent.path LIKE :path
        AND parent.node_type_id=3
      END_OF_SQL
      conditions = {:path => "#{self.path}%"}
      Node.find_by_sql([ERB.new(sql).result(binding), conditions])
    end

    def all_decendant_cases_with_plan
      sql = <<-'END_OF_SQL'
      SELECT distinct parent.*, tc.active, exists (SELECT * FROM impasse_test_plan_cases AS tpc WHERE tpc.test_case_id = parent.id) AS planned
        FROM impasse_nodes AS parent
      LEFT JOIN impasse_nodes AS child
        ON INSTR(child.path, parent.path) > 0
      LEFT JOIN impasse_test_cases AS tc
        ON child.id = tc.id
      WHERE parent.path LIKE :path
        AND parent.node_type_id=3
      END_OF_SQL
      conditions = {:path => "#{self.path}%"}
      Node.find_by_sql([ERB.new(sql).result(binding), conditions])
    end

    def save!
      if new_record?
        # dummy path
        write_attribute(:path, ".")
        super
      end

      recalculate_path
      super
    end

    def save
      if new_record?
        # dummy path
        write_attribute(:path, ".")
        return false unless super
      end

      recalculate_path
      super
    end

    def update_siblings_order!
      siblings = Node.find(:all,
                           :conditions=>["parent_id=? and id != ?", self.parent_id, self.id],
                           :order=>:node_order)
      if self.node_order < siblings.size
        siblings.insert(self.node_order, self)
      else
        siblings << self
      end
      
      change_nodes = []
      siblings.each_with_index do |sibling, i|
        next if sibling.id == self.id or sibling.node_order == i
        sibling.node_order = i
        change_nodes << sibling
      end

      change_nodes.each {|node| node.save! }
    end
 
    def update_child_nodes_path(old_path)
      sql = <<-END_OF_SQL
      UPDATE impasse_nodes
      SET path = replace(path, '#{old_path}', '#{self.path}')
      WHERE path like '#{old_path}_%'
      END_OF_SQL
      
      connection.update(sql)
    end

    private
    def recalculate_path
      if parent.nil?
        write_attribute(:path, ".#{read_attribute(:id)}.")
      else
        write_attribute(:path, "#{parent.path}#{read_attribute(:id)}.")
      end
    end
  end
end
