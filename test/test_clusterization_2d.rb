require_relative 'test_helper'
require 'minitest/autorun'
require 'genevalidator/clusterization'

module GeneValidator
  # test 2D clusterization
  class Test2DClusterization < Minitest::Test
    describe '2D clusterization' do
      vec1  = [Pair.new(1, 1), Pair.new(2, 2), Pair.new(1, 2), Pair.new(2, 1)]
      hash1 = Hash[vec1.group_by { |item| item }.map { |k, vs| [k, vs.length] }]
      clus1 = PairCluster.new(hash1)

      vec2  = [Pair.new(3, 1), Pair.new(4, 2), Pair.new(3, 2), Pair.new(4, 1)]
      hash2 = Hash[vec2.group_by { |item| item }.map { |k, vs| [k, vs.length] }]
      clus2 = PairCluster.new(hash2)

      it 'should calculate the mean of the cluster' do
        assert_equal(Pair.new(1.5, 1.5), clus1.mean)
      end

      it 'should calculate the distance between clusters ' do
        assert_equal(2.131078, clus1.distance(clus2).round(6))
      end

      it 'should do clusterization' do
        vec3     = [Pair.new(1, 1), Pair.new(1.2, 1), Pair.new(1, 1.5),
                    Pair.new(1.1, 1.3), Pair.new(0.9, 0.9), Pair.new(5, 10),
                    Pair.new(6, 10), Pair.new(5.5, 10.5)]
        hc       = HierarchicalClusterization.new(vec3)
        clusters = hc.hierarchical_clusterization_2d(2, 1)
        actual   = clusters[0].objects.map { |elem| elem[0] }
                   .sort { |a, b| a.x <=> b.x }
                   .sort { |a, b| a.y <=> b.y }
        ex_array = [Pair.new(1, 1), Pair.new(1.2, 1), Pair.new(1, 1.5),
                    Pair.new(1.1, 1.3), Pair.new(0.9, 0.9)]
        expected = ex_array.sort { |a, b| a.x <=> b.x }
                   .sort { |a, b| a.y <=> b.y }
        assert_equal(expected, actual)
      end
    end
  end
end
