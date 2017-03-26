#include "tools.fx"

//--------------------------
// direct light structure
//---------------------------
struct PointLight
{
	float3 position;
	float3 color;
};

//--------------------------
// material structure
//---------------------------
struct Material
{
	float3 diffAlbedo;
	float metallic;
	float3 specAlbedo;
	float roughness;
};

//-----------------------
//constant buffer
//---------------------
cbuffer cbPerFrame : register(b0)
{
	float3 gEyePosW;
	PointLight gPointLight;
	float4x4 gView;
	float4x4 gProj;
};

cbuffer cbPerObject : register(b1)
{
	float4x4 gWorld;
	float4x4 gWorldInverTrans;
	Material gMat;
};

//--------------------------
//read voxel from 3d texture
//---------------------------
Texture3D<float4> gVoxelList;

//----------------------
//shader structure
//--------------------
struct VS_IN
{
	float3 posL  : POSITION;
	float3 normL : NORMAL;
	float2 tex   : TEXCOORD;
};

struct VS_OUT
{
	float4 posW   : POSITION;
	uint3 pos_svo : SVO;
	float4 posH   : SV_POSITION;
	float3 normW  : NORMAL;
	float2 tex    : TEXCOORD;
};

//--------------------------
//direct diffuse lighting
//  c/PI
//---------------------------
float3 DirectDiffuseBRDF()
{
	return gMat.diffAlbedo/PI;
}

//--------------------------
//direct specular lighting
//  NDF * G * F / denominator
//---------------------------
void DirectSpecularBRDF(float3 N,float3 H,float3 L,float3 V,
						out float3 color,out float3 F)
{    
	// calculate reflectance at normal incidence; if dia-electric (like plastic) use F0 
    // of 0.04 and if it's a metal, use their albedo color as F0 (metallic workflow)    
	float3 metallic=gMat.metallic;

	float3 f0 = 0.04f; 
    f0 = lerp(f0, gMat.specAlbedo, metallic);

	F = Schlick_Fresnel(f0,H,V);
	float NDF = D_GGX(N, H, gMat.roughness);   
    float G = G_Smith(N, V, L, gMat.roughness);      

	float3 nominator = NDF * G * F; 
	float denominator = 4.0f * max(dot(N, V), 0.0f) * max(dot(N, L), 0.0f) + 0.001f;

	color = nominator / denominator;
}

//--------------------------
//composite spec and diff direct lighting
//---------------------------
float3 DirectLighting(float3 N,float3 H,float3 lightVec,float3 V, float3 L)
{
	float dist=length(lightVec);
	float att=5.0f/(dist*dist);
	float3 radiance=gPointLight.color*att;

	float3 kS=0.0f;
	float3 specBRDF=0.0f;

	DirectSpecularBRDF(N,H,L,V,specBRDF,kS);

	float3 kD = 1.0f - kS;
    kD *= 1.0f - gMat.metallic;	
	  
	float3 diffBRDF=DirectDiffuseBRDF();

	float NdotL = max(dot(N, L), 0.0);   
	float3 Lo = (kD * diffBRDF + specBRDF) * radiance * NdotL;

	float3 ambient = 0.3 * gMat.diffAlbedo * float3(0.8,0.8,0.8);

	float3 color=Lo+ambient;

	return color;
}

//--------------------------
//cone tracing
//---------------------------
float4 conetracing(float3 dir,float tanHalfAngle,float3 svo)
{
	float LOD=0.0f;
	float4 color=0.0f;
	float alpha=0.0f;

	float dist=1.0f;
	float3 startPos=svo;

	while(dist<10.0f)
	{
		float diameter=2.0f*tanHalfAngle*dist;
		float lodLevel=log2(diameter);
		float3 ray=startPos+dir*dist;

		float4 voxelColor=gVoxelList.SampleLevel(gAnisotropicSam, ray/256.0f ,lodLevel);
		color.rgb+=voxelColor.rgb;

        dist += diameter * 0.5; 
	}

	//todo it seems that pos_svo and world_to_svo(posW) have different result, dont know thy
	//float4 voxelColor=gVoxelList.SampleLevel(gAnisotropicSam, world_to_svo(ray,256.0f)/256.0f ,0);
	
	return color;
}

//--------------------------
//composite indirect lighting
//---------------------------
float4 InDirectLighting(float3 N,float3 svo)
{
	float4 color=0.0f;
	
	float4 occlusion=0.0f;

	color=conetracing(N,1,svo);

	return color;
}

//-----------------------------
//VERTEX SHADER
//-----------------------------
VS_OUT VS(VS_IN vin)
{
	VS_OUT vout;
	vout.posW=mul(float4(vin.posL,1.0f),gWorld);
	vout.pos_svo=ceil(vout.posW+128.0f);
	
	vout.posH=mul(vout.posW,gView);
	vout.posH=mul(vout.posH,gProj);

	vout.normW=mul(float4(vin.normL,1.0f),gWorldInverTrans).xyz;
	vout.tex=vin.tex;
	return vout;
}

//----------------------------
//PIXEL SHADER
//-------------------------
float4 PS(VS_OUT pin) : SV_Target
{
	float4 litColor=0.0f;
	float3 lightVec=gPointLight.position-pin.posW;

	float3 N=normalize(pin.normW);
	float3 V=normalize(gEyePosW-pin.posW);
	float3 L= normalize(lightVec);
	float3 H=normalize(V+L);

	float3 directlighting = DirectLighting(N, H, lightVec, V, L);
	float4 indirectlighting=InDirectLighting(N,pin.pos_svo);
	return float4(directlighting,1.0f);
}

RasterizerState SolidRS
{
	FillMode = SOLID;
	CullMode = None;
	FrontCounterClockwise = false;
};

technique11 ConeTracingTech
{
	pass ConeTracingPass
	{
		SetVertexShader(CompileShader(vs_5_0, VS()));
		SetGeometryShader(NULL);
		SetPixelShader(CompileShader(ps_5_0, PS()));
		SetRasterizerState(SolidRS);
	}
}