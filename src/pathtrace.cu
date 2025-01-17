#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>
#include <thrust/partition.h>
#include <thrust/device_ptr.h>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"

#include <device_launch_parameters.h>

#define ERRORCHECK 1
#define STREAM_COMPACTION 1
#define ANTIALIASING 0
#define CACHE_FIRST_BOUNCE 0
#define SORT_BY_MAT 0
#define NOR 1
#define POS 2
#define G_BUFFER_IMG_MODE POS
#define PERFORMANCE_TIME 1

#if PERFORMANCE_TIME
cudaEvent_t start, stop;
#endif

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)

void checkCUDAErrorFn(const char* msg, const char* file, int line) {
#if ERRORCHECK
	cudaDeviceSynchronize();
	cudaError_t err = cudaGetLastError();
	if (cudaSuccess == err) {
		return;
	}

	fprintf(stderr, "CUDA error");
	if (file) {
		fprintf(stderr, " (%s:%d)", file, line);
	}
	fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#  ifdef _WIN32
	getchar();
#  endif
	exit(EXIT_FAILURE);
#endif
}

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
	int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
	return thrust::default_random_engine(h);
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
	int iter, glm::vec3* image) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int index = x + (y * resolution.x);
		glm::vec3 pix = image[index];

		glm::ivec3 color;
		color.x = glm::clamp((int)(pix.x / iter * 255.0), 0, 255);
		color.y = glm::clamp((int)(pix.y / iter * 255.0), 0, 255);
		color.z = glm::clamp((int)(pix.z / iter * 255.0), 0, 255);

		// Each thread writes one pixel location in the texture (textel)
		pbo[index].w = 0;
		pbo[index].x = color.x;
		pbo[index].y = color.y;
		pbo[index].z = color.z;
	}
}

//the following 3 helper functions are for oct-eocoding normal
//reference: https://jcgt.org/published/0003/02/01/paper.pdf
__host__ __device__ glm::vec2 signNotZero(glm::vec2 v) {
	return glm::vec2((v.x >= 0) ? 1.f : -1.f, (v.y >= 0) ? 1.f : -1.f);
}

__host__ __device__ glm::vec2 float32x3_to_oct(glm::vec3 v) {
	glm::vec2 p = glm::vec2(v) * (1.f / (abs(v.x) + abs(v.y) + abs(v.z)));
	return (v.z <= 0) ? ((1.f - abs(p)) * signNotZero(p)) : p;
}

__host__ __device__ glm::vec3 oct_to_float32x3(glm::vec2 e) {
	float z = 1.f - abs(e.x) - abs(e.y);
	if (z < 0) {
		e = (1.f - abs(e)) * signNotZero(e);
	}
	return normalize(glm::vec3(e, z));
}

__host__ __device__ glm::vec3 depthToPos(float depth, float x, float y, const Camera& cam) {
	glm::vec3 dir = glm::normalize(cam.view
		- cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * 0.5f)
		- cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * 0.5f));
	return cam.position + depth * dir;
}

__global__ void gbufferToPBO(uchar4* pbo, glm::ivec2 resolution, GBufferPixel* gBuffer) {
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {
		int idx = x + (y * resolution.x);

#if Z_DEPTH
		glm::vec3 pos = glm::vec3(gBuffer[idx].z);
#else 
		glm::vec3 pos = gBuffer[idx].pos;
#endif //Z_DEPTH

#if OCT_ENCODING_NOR
		glm::vec3 normal = oct_to_float32x3(gBuffer[idx].octNormal);
#else
		glm::vec3 normal = gBuffer[idx].normal;
#endif //OCT_ENCODING_NOR

#if G_BUFFER_IMG_MODE == NOR
		normal = glm::abs(normal * 255.f);
		pbo[idx].w = 0;
		pbo[idx].x = normal.x;
		pbo[idx].y = normal.y;
		pbo[idx].z = normal.z;

#elif G_BUFFER_IMG_MODE == POS

#if !Z_DEPTH
		pos = glm::clamp(glm::abs(pos * 25.f), 0.f, 255.f);
#else
		pos = glm::clamp(glm::abs(pos * 5.f), 0.f, 255.f);
#endif
		pbo[idx].w = 0;
		pbo[idx].x = pos.x;
		pbo[idx].y = pos.y;
		pbo[idx].z = pos.z;

#else
		float timeToIntersect = gBuffer[idx].t * 256.0;

		pbo[idx].w = 0;
		pbo[idx].x = timeToIntersect;
		pbo[idx].y = timeToIntersect;
		pbo[idx].z = timeToIntersect;
#endif //G_BUFFER_IMG
	}
}

static Scene* hst_scene = NULL;
static GuiDataContainer* guiData = NULL;
static glm::vec3* dev_image = NULL;
static Geom* dev_geoms = NULL;
static Material* dev_materials = NULL;
static PathSegment* dev_paths = NULL;
static PathSegment* dev_cache_paths = NULL;
static ShadeableIntersection* dev_intersections = NULL;
static GBufferPixel* dev_gBuffer = NULL;
static glm::vec3* dev_blurredImg = nullptr;
// TODO: static variables for device memory, any extra info you need, etc
// ...
static Triangle* dev_triangles = NULL;
static glm::vec3* dev_maps = NULL;



void pathtraceInit(Scene* scene) {
	hst_scene = scene;

	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
	cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));

	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

	cudaMalloc(&dev_gBuffer, pixelcount * sizeof(GBufferPixel));
	cudaMalloc(&dev_blurredImg, pixelcount * sizeof(glm::vec3));

	// TODO: initialize any extra device memeory you need
	cudaMalloc(&dev_cache_paths, pixelcount * sizeof(PathSegment));
	cudaMemset(dev_cache_paths, 0, pixelcount * sizeof(PathSegment));

	cudaMalloc(&dev_triangles, scene->triangles.size() * sizeof(Triangle));
	cudaMemcpy(dev_triangles, scene->triangles.data(), scene->triangles.size() * sizeof(Triangle), cudaMemcpyHostToDevice);
	if (scene->maps.size() > 0)
	{
		cudaMalloc(&dev_maps, scene->maps.size() * sizeof(glm::vec3));
		cudaMemcpy(dev_maps, scene->maps.data(), scene->maps.size() * sizeof(glm::vec3), cudaMemcpyHostToDevice);
	}
	checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
	cudaFree(dev_image);  // no-op if dev_image is null
	cudaFree(dev_paths);
	cudaFree(dev_geoms);
	cudaFree(dev_materials);
	cudaFree(dev_intersections);
	cudaFree(dev_gBuffer);
	cudaFree(dev_blurredImg);

	// TODO: clean up any extra device memory you created
	cudaFree(dev_cache_paths);
	cudaFree(dev_triangles);
	cudaFree(dev_maps);

	checkCUDAError("pathtraceFree");
}

/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
		PathSegment& segment = pathSegments[index];

		segment.ray.origin = cam.position;
		segment.color = glm::vec3(1.0f, 1.0f, 1.0f);
		thrust::default_random_engine rng = makeSeededRandomEngine(iter, index, 0);
		thrust::uniform_real_distribution<float> u01(0, 1);
		// TODO: implement antialiasing by jittering the ray
#if		ANTIALIASING && !CACHE_FIRST_BOUNCE
		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * 0.5f + u01(rng) - 0.5f)
			- cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * 0.5f + u01(rng) - 0.5f)
		);

#elif   !CACHE_FIRST_BOUNCE
		//depth of field
		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * 0.5f)
			- cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * 0.5f)
		);
		if (cam.aperture > 0)
		{
			glm::vec3 forward = glm::normalize(cam.lookAt - cam.position);
			glm::vec3 right = glm::normalize(glm::cross(forward, cam.up));
			glm::vec3 focalPoint = segment.ray.origin + cam.focalLength * segment.ray.direction;

			float angle = u01(rng) * 2.f * PI;
			float radius = cam.aperture * glm::sqrt(u01(rng));

			segment.ray.origin += radius * (cos(angle) * right + sin(angle) * cam.up);
			segment.ray.direction = glm::normalize(focalPoint - segment.ray.origin);
		}


#endif

		segment.pixelIndex = index;
		segment.remainingBounces = traceDepth;
	}
}

// TODO:
// computeIntersections handles generating ray intersections ONLY.
// Generating new rays is handled in your shader(s).
// Feel free to modify the code below.
__global__ void computeIntersections(
	int depth
	, int num_paths
	, PathSegment* pathSegments
	, Geom* geoms
	, int geoms_size
	, ShadeableIntersection* intersections
	, Triangle* triangles
	, Material* materials
	, glm::vec3* maps
)
{
	int path_index = blockIdx.x * blockDim.x + threadIdx.x;

	if (path_index < num_paths)
	{
		PathSegment pathSegment = pathSegments[path_index];

#if (STREAM_COMPACTION == 0)
		if (pathSegment.remainingBounces <= 0)
		{
			intersections[path_index].t = -1.f;
			return;
		}
#endif

		float t;
		glm::vec3 intersect_point;
		glm::vec3 normal;
		glm::vec2 uv;
		float t_min = FLT_MAX;
		int hit_geom_index = -1;
		bool outside = true;

		glm::vec3 tmp_intersect;
		glm::vec3 tmp_normal;
		glm::vec2 tmp_uv;
		// naive parse through global geoms

		for (int i = 0; i < geoms_size; i++)
		{
			Geom& geom = geoms[i];
			if (geom.type == MESH)
			{
				for (int j = geom.mesh_start_idx; j < geom.mesh_end_idx; j++)
				{
					t = triangleIntersectionTest(geom, triangles[j], materials[geom.materialid], maps, pathSegment.ray, tmp_intersect, tmp_normal, tmp_uv);
					if (t > 0.f && t_min > t)
					{
						t_min = t;
						hit_geom_index = i;
						intersect_point = tmp_intersect;
						normal = tmp_normal;
						uv = tmp_uv;
					}
				}

			}
			else
			{
				if (geom.type == CUBE)
				{
					t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
				}
				else if (geom.type == SPHERE)
				{
					t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
				}
				if (t > 0.0f && t_min > t)
				{
					t_min = t;
					hit_geom_index = i;
					intersect_point = tmp_intersect;
					normal = tmp_normal;
				}
			}
		}

		if (hit_geom_index == -1)
		{
			intersections[path_index].t = -1.0f;
		}
		else
		{
			//The ray hits something
			intersections[path_index].t = t_min;
			intersections[path_index].materialId = geoms[hit_geom_index].materialid;
			intersections[path_index].surfaceNormal = normal;
			intersections[path_index].uv = uv;
		}
	}
}

// LOOK: "fake" shader demonstrating what you might do with the info in
// a ShadeableIntersection, as well as how to use thrust's random number
// generator. Observe that since the thrust random number generator basically
// adds "noise" to the iteration, the image should start off noisy and get
// cleaner as more iterations are computed.
//
// Note that this shader does NOT do a BSDF evaluation!
// Your shaders should handle that - this can allow techniques such as
// bump mapping.
__global__ void shadeFakeMaterial(
	int iter
	, int num_paths
	, ShadeableIntersection* shadeableIntersections
	, PathSegment* pathSegments
	, Material* materials
)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		ShadeableIntersection intersection = shadeableIntersections[idx];
		if (intersection.t > 0.0f) { // if the intersection exists...
		  // Set up the RNG
		  // LOOK: this is how you use thrust's RNG! Please look at
		  // makeSeededRandomEngine as well.
			thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);
			thrust::uniform_real_distribution<float> u01(0, 1);

			Material material = materials[intersection.materialId];
			glm::vec3 materialColor = material.color;

			// If the material indicates that the object was a light, "light" the ray
			if (material.emittance > 0.0f) {
				pathSegments[idx].color *= (materialColor * material.emittance);
			}
			// Otherwise, do some pseudo-lighting computation. This is actually more
			// like what you would expect from shading in a rasterizer like OpenGL.
			// TODO: replace this! you should be able to start with basically a one-liner
			else {
				float lightTerm = glm::dot(intersection.surfaceNormal, glm::vec3(0.0f, 1.0f, 0.0f));
				pathSegments[idx].color *= (materialColor * lightTerm) * 0.3f + ((1.0f - intersection.t * 0.02f) * materialColor) * 0.7f;
				pathSegments[idx].color *= u01(rng); // apply some noise because why not
				pathSegments[idx].remainingBounces--;
			}
			// If there was no intersection, color the ray black.
			// Lots of renderers use 4 channel color, RGBA, where A = alpha, often
			// used for opacity, in which case they can indicate "no opacity".
			// This can be useful for post-processing and image compositing.
		}
		else {
			pathSegments[idx].color = glm::vec3(0.0f);
		}
	}
}

__global__ void shadeMaterial(
	int iter
	, int num_paths
	, ShadeableIntersection* shadeableIntersections
	, PathSegment* pathSegments
	, Material* materials
	, glm::vec3* dev_maps
)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		ShadeableIntersection intersection = shadeableIntersections[idx];
		if (intersection.t > 0.0f) { // if the intersection exists...
		  // Set up the RNG
		  // LOOK: this is how you use thrust's RNG! Please look at
		  // makeSeededRandomEngine as well.
			thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);
			thrust::uniform_real_distribution<float> u01(0, 1);

			Material material = materials[intersection.materialId];
			glm::vec3 materialColor = material.color;

			// If the material indicates that the object was a light, "light" the ray
			if (material.emittance > 0.0f) {
				pathSegments[idx].color *= (materialColor * material.emittance);
				pathSegments[idx].remainingBounces = 0;
			}
			// Otherwise, do some pseudo-lighting computation. This is actually more
			// like what you would expect from shading in a rasterizer like OpenGL.
			// TODO: replace this! you should be able to start with basically a one-liner
			else {
				glm::vec3 intersect_point = getPointOnRay(pathSegments[idx].ray, intersection.t);
				scatterRay(pathSegments[idx], intersect_point, intersection.surfaceNormal, material, rng, intersection.uv, dev_maps);
				pathSegments[idx].remainingBounces--;
			}
			// If there was no intersection, color the ray black.
			// Lots of renderers use 4 channel color, RGBA, where A = alpha, often
			// used for opacity, in which case they can indicate "no opacity".
			// This can be useful for post-processing and image compositing.
		}
		else {
			pathSegments[idx].color = glm::vec3(0.0f);
			pathSegments[idx].remainingBounces = 0;
		}
	}
}

// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, glm::vec3* image, PathSegment* iterationPaths)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < nPaths)
	{
		PathSegment iterationPath = iterationPaths[index];
		image[iterationPath.pixelIndex] += iterationPath.color;
	}
}

__global__ void generateGBuffer(
	int num_paths,
	ShadeableIntersection* shadeableIntersections,
	PathSegment* pathSegments,
	GBufferPixel* gBuffer) {
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
#if Z_DEPTH
		gBuffer[idx].z = shadeableIntersections[idx].t;
#else
		
		gBuffer[idx].pos = getPointOnRay(pathSegments[idx].ray, shadeableIntersections[idx].t);
#endif //Z_DEPTH

#if OCT_ENCODING_NOR
		gBuffer[idx].octNormal = float32x3_to_oct(shadeableIntersections[idx].surfaceNormal);
#else
		gBuffer[idx].normal = shadeableIntersections[idx].surfaceNormal;
#endif //OCT_ENCODING_NOR
	}
}

struct sort_material {
	__host__ __device__ bool operator()(const ShadeableIntersection& m1, const ShadeableIntersection& m2) {
		return m1.materialId < m2.materialId;
	}
};

struct is_bouncing
{
	__host__ __device__
		bool operator()(const PathSegment& seg)
	{
		return seg.remainingBounces > 0;
	}
};

/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(int frame, int iter) {
	const int traceDepth = hst_scene->state.traceDepth;
	const Camera& cam = hst_scene->state.camera;
	const int pixelcount = cam.resolution.x * cam.resolution.y;

	// 2D block for generating ray from camera
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

	///////////////////////////////////////////////////////////////////////////

	// Recap:
	// * Initialize array of path rays (using rays that come out of the camera)
	//   * You can pass the Camera object to that kernel.
	//   * Each path ray must carry at minimum a (ray, color) pair,
	//   * where color starts as the multiplicative identity, white = (1, 1, 1).
	//   * This has already been done for you.
	// * For each depth:
	//   * Compute an intersection in the scene for each path ray.
	//     A very naive version of this has been implemented for you, but feel
	//     free to add more primitives and/or a better algorithm.
	//     Currently, intersection distance is recorded as a parametric distance,
	//     t, or a "distance along the ray." t = -1.0 indicates no intersection.
	//     * Color is attenuated (multiplied) by reflections off of any object
	//   * TODO: Stream compact away all of the terminated paths.
	//     You may use either your implementation or `thrust::remove_if` or its
	//     cousins.
	//     * Note that you can't really use a 2D kernel launch any more - switch
	//       to 1D.
	//   * TODO: Shade the rays that intersected something or didn't bottom out.
	//     That is, color the ray by performing a color computation according
	//     to the shader, then generate a new ray to continue the ray path.
	//     We recommend just updating the ray's PathSegment in place.
	//     Note that this step may come before or after stream compaction,
	//     since some shaders you write may also cause a path to terminate.
	// * Finally, add this iteration's results to the image. This has been done
	//   for you.

	// TODO: perform one iteration of path tracing

#if CACHE_FIRST_BOUNCE 

	if (iter == 1)
	{
		generateRayFromCamera << <blocksPerGrid2d, blockSize2d >> > (cam, iter, traceDepth, dev_paths);
		checkCUDAError("generate camera ray");

		cudaMemcpy(dev_cache_paths, dev_paths, pixelcount * sizeof(PathSegment), cudaMemcpyDeviceToDevice);
	}
	else
	{
		cudaMemcpy(dev_paths, dev_cache_paths, pixelcount * sizeof(PathSegment), cudaMemcpyDeviceToDevice);
	}
#else
	generateRayFromCamera << <blocksPerGrid2d, blockSize2d >> > (cam, iter, traceDepth, dev_paths);
	checkCUDAError("generate camera ray");

#endif //CACHE_FIRST_BOUNCE

	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int num_paths = dev_path_end - dev_paths;

	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks
	
	// Empty gbuffer
	cudaMemset(dev_gBuffer, 0, pixelcount * sizeof(GBufferPixel));

	bool iterationComplete = false;
	while (!iterationComplete) {

		// clean shading chunks
		cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

		// tracing
		dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;
		computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
			depth
			, num_paths
			, dev_paths
			, dev_geoms
			, hst_scene->geoms.size()
			, dev_intersections
			, dev_triangles
			, dev_materials
			, dev_maps
			);
		checkCUDAError("trace one bounce");
		cudaDeviceSynchronize();

		//material sorting
#if SORT_BY_MAT
		thrust::sort_by_key(thrust::device, dev_intersections, dev_intersections + num_paths, dev_paths, sort_material());
#endif //SORT BY MAT

		if (depth == 0)
		{
			generateGBuffer << <numblocksPathSegmentTracing, blockSize1d >> > (num_paths, dev_intersections, dev_paths, dev_gBuffer);
		}
		depth++;


		// TODO:
		// --- Shading Stage ---
		// Shade path segments based on intersections and generate new rays by
	  // evaluating the BSDF.
	  // Start off with just a big kernel that handles all the different
	  // materials you have in the scenefile.
	  // TODO: compare between directly shading the path segments and shading
	  // path segments that have been reshuffled to be contiguous in memory.

		shadeMaterial << <numblocksPathSegmentTracing, blockSize1d >> > (
			iter,
			num_paths,
			dev_intersections,
			dev_paths,
			dev_materials,
			dev_maps
			);
		

		//stream compaction for path segments
		if (depth >= hst_scene->state.traceDepth)
		{
			break;
		}
		PathSegment* remaining_path_end = thrust::stable_partition(thrust::device, dev_paths, dev_path_end, is_bouncing());
		num_paths = remaining_path_end - dev_paths;

		if (num_paths == 0) {
			iterationComplete = true;
		} // TODO: should be based off stream compaction results.
	}

	// Assemble this iteration and apply it to the image
	dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
	num_paths = dev_path_end - dev_paths;
	finalGather << <numBlocksPixels, blockSize1d >> > (num_paths, dev_image, dev_paths);

	///////////////////////////////////////////////////////////////////////////

	// Retrieve image from GPU
	cudaMemcpy(hst_scene->state.image.data(), dev_image,
		pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

	checkCUDAError("pathtrace");
}

void showGBuffer(uchar4* pbo) {
	const Camera& cam = hst_scene->state.camera;
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	gbufferToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, dev_gBuffer);
}

void showImage(uchar4* pbo, int iter) {
	const Camera& cam = hst_scene->state.camera;
	const dim3 blockSize2d(8, 8);
	const dim3 blocksPerGrid2d(
		(cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
		(cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// Send results to OpenGL buffer for rendering
	sendImageToPBO << <blocksPerGrid2d, blockSize2d >> > (pbo, cam.resolution, iter, dev_image);
}

__device__ glm::vec3 depth2Pos(Camera cam, float t, float x, float y) {
	glm::vec3 dir = glm::normalize(cam.view - cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * 0.5f) - cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * 0.5f));
	return cam.position + dir * t;
}

//reference: https://jo.dreggn.org/home/2010_atrous.pdf
__global__ void aTrousFilter
(
	Camera cam,
	glm::ivec2 resolution,
	int stepWidth, 
	float c_phi,
	float n_phi, 
	float p_phi,
	const glm::vec3* img,
	const GBufferPixel* gBuffer,
	glm::vec3* blurredImg) {

	int x = blockDim.x * blockIdx.x + threadIdx.x;
	int y = blockDim.y * blockIdx.y + threadIdx.y;

	if (x < resolution.x && y < resolution.y) {

		int idx = y * resolution.x + x;
		constexpr float kernel[5] = {0.0625f, 0.25f, 0.375f, 0.25f, 0.0625f};

		glm::vec3 sum(0.f);
		float cum_w = 0.f;

		for (int i = 0; i < 5; ++i)
		{
			for (int j = 0; j < 5; ++j)
			{
				int tx = glm::clamp(x + (i - 2) * stepWidth, 0, resolution.x);
				int ty = glm::clamp(y + (j - 2) * stepWidth, 0, resolution.y);
				int t_idx = ty * resolution.x + tx;

				glm::vec3 ctmp = img[t_idx];
				glm::vec3 t = img[idx] - ctmp;
				float dist2 = glm::dot(t, t);
				float c_w = min(exp(-dist2 / c_phi), 1.f);
#if OCT_ENCODING_NOR
				t = oct_to_float32x3(gBuffer[idx].octNormal) - oct_to_float32x3(gBuffer[t_idx].octNormal);
#else
				t = gBuffer[idx].normal - gBuffer[t_idx].normal;
#endif //OCT_ENCODING_NOR

				dist2 = glm::length(t);
				float n_w = min(exp(-dist2 / n_phi), 1.f);

#if Z_DEPTH
				t = depth2Pos(cam, gBuffer[idx].z, x, y) - depth2Pos(cam, gBuffer[t_idx].z, x, y);
#else
				t = gBuffer[idx].pos - gBuffer[t_idx].pos;
#endif //Z_DEPTH
				dist2 = glm::dot(t, t);
				float p_w = min(exp(-dist2 / p_phi), 1.f);

				float weight = c_w * n_w * p_w;
				sum += ctmp * weight * kernel[i] * kernel[j];
				cum_w += weight * kernel[i] * kernel[j];
			}
		}
		blurredImg[idx] = sum / cum_w;
	}
}

void denoise()
{
	const glm::ivec2 resolution = hst_scene->state.camera.resolution;
	const Camera& cam = hst_scene->state.camera;
	const dim3 blockSize2d(32, 32);
	const dim3 blocksPerGrid2d((resolution.x + blockSize2d.x - 1) / blockSize2d.x, (resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	//performance time tracking
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

#if PERFORMANCE_TIME
	cudaEventRecord(start);
#endif

	for (int stepWidth = 1; stepWidth * 4 + 1 <= ui_filterSize; stepWidth *= 2)
	{
		aTrousFilter << <blocksPerGrid2d, blockSize2d >> > (cam, resolution, stepWidth, ui_colorWeight, ui_normalWeight, ui_positionWeight, dev_image, dev_gBuffer, dev_blurredImg);
		std::swap(dev_image, dev_blurredImg);
	}
#if PERFORMANCE_TIME
	cudaEventRecord(stop);
#endif
	cudaMemcpy(hst_scene->state.image.data(), dev_image, resolution.x * resolution.y * sizeof(glm::vec3), cudaMemcpyDeviceToHost);
	
#if PERFORMANCE_TIME
	cudaEventSynchronize(stop);
	float milliseconds = 0;
	cudaEventElapsedTime(&milliseconds, start, stop);
	std::cout << "denoise took :" << milliseconds << std::endl;
#endif
}
