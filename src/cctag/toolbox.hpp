#ifndef VISION_MARKER_TOOLBOX_HPP_
#define VISION_MARKER_TOOLBOX_HPP_

#include <list>
#include <string>
#include <vector>

#include <cctag/geometry/point.hpp>

namespace cctag {
class EdgePoint;
namespace numerical {
namespace geometry {
class Ellipse;
}
}
}

namespace cctag {
namespace numerical {

// Precondition : pts.size >=2
// TODO déplacer innerProdMin
double innerProdMin( const std::vector<cctag::EdgePoint*>& childrens, double thrCosDiffMax, Point2dN<int> & p1, Point2dN<int> & p2 );

void circleFitting(cctag::numerical::geometry::Ellipse& e, const std::vector<cctag::EdgePoint*>& points);

void ellipseFitting( cctag::numerical::geometry::Ellipse& e, const std::vector< Point2dN<double> >& childrens );

void ellipseFitting( cctag::numerical::geometry::Ellipse& e, const std::vector<cctag::EdgePoint*>& childrens );

void ellipseFitting( cctag::numerical::geometry::Ellipse& e, const std::list<cctag::EdgePoint*>& childrens );

bool matrixFromFile( const std::string& filename, std::list<cctag::EdgePoint>& edgepoints );

int discreteEllipsePerimeter( const cctag::numerical::geometry::Ellipse& ellipse);

}
}

#endif
